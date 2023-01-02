unit DelphiLintServer;

interface

uses
    IdHTTP
  , IdTCPClient
  , JSON
  , System.Classes
  , System.SysUtils
  , DelphiLintData
  , System.Generics.Collections
  , Windows
  ;

const
  C_Ping = 1;
  C_Pong = 5;
  C_Initialize = 20;
  C_Analyze = 30;
  C_AnalyzeResult = 35;
  C_AnalyzeError = 36;
  C_Initialized = 25;
  C_Uninitialized = 26;
  C_InvalidRequest = 241;
  C_UnexpectedError = 242;

type

//______________________________________________________________________________________________________________________

  TLintMessage = class(TObject)
  private
    FCategory: Byte;
    FData: TJsonObject;
  public
    constructor Create(Category: Byte; Data: TJsonObject);
    destructor Destroy; override;
    class function Initialize(Data: TJsonObject): TLintMessage; static;
    class function Analyze(Data: TJsonObject): TLintMessage; static;
    property Category: Byte read FCategory;
    property Data: TJsonObject read FData;
  end;

//______________________________________________________________________________________________________________________

  TLintResponseAction = reference to procedure (Message: TLintMessage);
  TLintAnalyzeAction = reference to procedure(Issues: TArray<TLintIssue>);

  TLintServer = class(TThread)
  private
    FTcpClient: TIdTCPClient;
    FSonarHostUrl: string;
    FResponseActions: TDictionary<Integer, TLintResponseAction>;
    FNextId: Integer;
    FCriticalSection: TRTLCriticalSection;

    procedure SendMessage(Req: TLintMessage; OnResponse: TLintResponseAction); overload;
    procedure SendMessage(Req: TLintMessage; Id: Integer); overload;
    procedure OnUnhandledMessage(Message: TLintMessage);
    procedure ReceiveMessage;

  public
    constructor Create(SonarHostUrl: string);
    destructor Destroy; override;

    procedure Execute; override;

    procedure Initialize;
    procedure Analyze(BaseDir: string; DelphiFiles: array of string; OnAnalyze: TLintAnalyzeAction);
  end;

//______________________________________________________________________________________________________________________

implementation

uses
    IdGlobal
  , Vcl.Dialogs
  ;

//______________________________________________________________________________________________________________________

class function TLintMessage.Analyze(Data: TJsonObject): TLintMessage;
begin
  Result := TLintMessage.Create(C_Analyze, Data);
end;

//______________________________________________________________________________________________________________________

constructor TLintMessage.Create(Category: Byte; Data: TJsonObject);
begin
  FCategory := Category;
  FData := Data;
end;

//______________________________________________________________________________________________________________________

destructor TLintMessage.Destroy;
begin
  FreeAndNil(FData);
  inherited;
end;

//______________________________________________________________________________________________________________________

class function TLintMessage.Initialize(Data: TJsonObject): TLintMessage;
begin
  Result := TLintMessage.Create(C_Initialize, Data);
end;

//______________________________________________________________________________________________________________________

constructor TLintServer.Create(SonarHostUrl: string);
begin
  inherited Create(False);
  InitializeCriticalSection(FCriticalSection);
  Priority := tpNormal;

  FSonarHostUrl := SonarHostUrl;
  FNextId := 1;

  FResponseActions := TDictionary<Integer, TLintResponseAction>.Create;
  FTcpClient := TIdTCPClient.Create;
  FTcpClient.Host := '127.0.0.1';
  FTcpClient.Port := 14000;
  FTcpClient.Connect;
end;

//______________________________________________________________________________________________________________________

destructor TLintServer.Destroy;
begin
  FreeAndNil(FTcpClient);
  DeleteCriticalSection(FCriticalSection);
  inherited;
end;

//______________________________________________________________________________________________________________________

procedure TLintServer.Execute;
begin
  inherited;
  while True do begin
    ReceiveMessage;
  end;
end;

//______________________________________________________________________________________________________________________

procedure TLintServer.Analyze(BaseDir: string; DelphiFiles: array of string; OnAnalyze: TLintAnalyzeAction);
var
  Index: Integer;
  RequestJson: TJsonObject;
  InputFilesJson: TJsonArray;
begin
  Initialize;

  InputFilesJson := TJsonArray.Create;

  for Index := 0 to Length(DelphiFiles) - 1 do begin
    InputFilesJson.Add(DelphiFiles[Index]);
  end;

  // JSON representation of au.com.integradev.delphilint.messaging.RequestAnalyze
  RequestJson := TJsonObject.Create;
  RequestJson.AddPair('baseDir', BaseDir);
  RequestJson.AddPair('inputFiles', InputFilesJson);

  SendMessage(
    TLintMessage.Analyze(RequestJson),
    procedure(Response: TLintMessage)
    var
      IssuesJson: TJsonValue;
      IssuesArrayJson: TJsonArray;
      Index: Integer;
      Issues: TArray<TLintIssue>;
    begin
      Assert(Response.Category = C_AnalyzeResult);

      IssuesJson := Response.Data.GetValue('issues');
      if IssuesJson is TJsonArray then begin
        IssuesArrayJson := IssuesJson as TJsonArray;
        SetLength(Issues, IssuesArrayJson.Count);

        for Index := 0 to IssuesArrayJson.Count - 1 do begin
          Issues[Index] := TLintIssue.FromJson(IssuesArrayJson[Index] as TJsonObject);
        end;
      end;

      FreeAndNil(Response);

      Synchronize(
        procedure begin
          OnAnalyze(Issues);
        end);
    end);

end;

//______________________________________________________________________________________________________________________

procedure TLintServer.Initialize;
const
  C_BdsPath = '{PATH REMOVED} Files (x86)/Embarcadero/Studio/22.0';
  C_CompilerVersion = 'VER350';
  C_LanguageKey = 'delph';
var
  DataJson: TJsonObject;
begin
  // JSON representation of au.com.integradev.delphilint.messaging.RequestInitialize
  DataJson := TJSONObject.Create;
  DataJson.AddPair('bdsPath', C_BdsPath);
  DataJson.AddPair('compilerVersion', C_CompilerVersion);
  DataJson.AddPair('sonarHostUrl', FSonarHostUrl);
  DataJson.AddPair('projectKey', '');
  DataJson.AddPair('languageKey', C_LanguageKey);

  SendMessage(
    TLintMessage.Initialize(DataJson),
    procedure(Response: TLintMessage) begin

    end);
end;

//______________________________________________________________________________________________________________________

procedure TLintServer.OnUnhandledMessage(Message: TLintMessage);
begin
  ShowMessage(Format('Unhandled message (code %d) received: <%s>', [Message.Category, Message.Data]));
end;

//______________________________________________________________________________________________________________________

procedure TLintServer.SendMessage(Req: TLintMessage; Id: Integer);
var
  DataBytes: TArray<Byte>;
  DataByte: Byte;
begin
  EnterCriticalSection(FCriticalSection);
  FTcpClient.IOHandler.Write(Req.Category);
  FTcpClient.IOHandler.Write(Id);

  DataBytes := TEncoding.UTF8.GetBytes(Req.Data.Tostring);

  FTcpClient.IOHandler.Write(Length(DataBytes));
  for DataByte in DataBytes do begin
    FTcpClient.IOHandler.Write(DataByte);
  end;
  LeaveCriticalSection(FCriticalSection);
end;

//______________________________________________________________________________________________________________________

procedure TLintServer.SendMessage(Req: TLintMessage; OnResponse: TLintResponseAction);
var
  Id: SmallInt;
begin
  EnterCriticalSection(FCriticalSection);
  Id := FNextId;
  Inc(FNextId);

  FResponseActions.Add(Id, OnResponse);
  SendMessage(Req, Id);
  LeaveCriticalSection(FCriticalSection);
end;

//______________________________________________________________________________________________________________________

procedure TLintServer.ReceiveMessage;
var
  Id: SmallInt;
  Category: Byte;
  Length: Integer;
  DataStr: string;
  DataJsonValue: TJsonValue;
  DataJson: TJsonObject;
  Message: TLintMessage;
begin
  EnterCriticalSection(FCriticalSection);

  Category := FTcpClient.IOHandler.ReadByte;
  Id := FTcpClient.IOHandler.ReadInt32;
  Length := FTcpClient.IOHandler.ReadInt32;
  DataStr := FTcpClient.IOHandler.ReadString(Length, IndyTextEncoding_UTF8);
  DataJsonValue := TJsonObject.ParseJSONValue(DataStr);

  DataJson := nil;
  if (DataJsonValue is TJsonObject) then begin
    DataJson := DataJsonValue as TJsonObject;
  end;

  LeaveCriticalSection(FCriticalSection);

  Message := TLintMessage.Create(Category, DataJson);

  if FResponseActions.ContainsKey(Id) then begin
    FResponseActions[Id](Message);
  end
  else begin
    OnUnhandledMessage(Message);
  end;
end;

//______________________________________________________________________________________________________________________

end.