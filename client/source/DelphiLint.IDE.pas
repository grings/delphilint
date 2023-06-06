unit DelphiLint.IDE;

interface

uses
    System.SysUtils
  , ToolsAPI
  , DelphiLint.Server
  , Vcl.Dialogs
  , Vcl.Graphics
  , WinAPI.Windows
  , System.Classes
  , System.Generics.Collections
  , DelphiLint.Data
  , DelphiLint.Logger
  , DockForm
  , DelphiLint.Events
  , DelphiLint.ProjectOptions
  , DelphiLint.EditorSync
  , DelphiLint.IDEUtils
  ;

type

//______________________________________________________________________________________________________________________

  TIDERefreshEvent = procedure(Issues: TArray<TLintIssue>);

//______________________________________________________________________________________________________________________

  TLintMenuItem = class(TNotifierObject, IOTAWizard, IOTAMenuWizard)
  public type
    TMenuItemAction = reference to procedure;
  private
    FName: string;
    FCaption: string;
    FAction: TMenuItemAction;
  public
    constructor Create(Name: string; Caption: string; Action: TMenuItemAction);

    function GetIDstring: string;
    function GetName: string;
    function GetState: TWizardState;
    procedure Execute;
    function GetMenuText: string;
  end;

  TLintEditor = class(TEditorNotifierBase)
  private
    FNotifiers: TList<TNotifierBase>;
    FTrackers: TObjectList<TEditorLineTracker>;
    FInitedViews: TList<IOTAEditView>;

    procedure OnTrackedLineChanged(const ChangedLine: TChangedLine);

    procedure InitView(const View: IOTAEditView);
    function IsViewInited(const View: IOTAEditView): Boolean;
    procedure OnAnalysisComplete(const Issues: TArray<TLintIssue>);
  public
    constructor Create;
    destructor Destroy; override;
    procedure ViewNotification(const View: IOTAEditView; Operation: TOperation); override;
    procedure EditorViewActivated(const EditWindow: INTAEditWindow; const EditView: IOTAEditView); override;
  end;

  TLintView = class(TViewNotifierBase)
  private
    FRepaint: Boolean;
    procedure OnAnalysisComplete(const Issues: TArray<TLintIssue>);
  public
    constructor Create;
    destructor Destroy; override;
    procedure EditorIdle(const View: IOTAEditView); override;
    procedure BeginPaint(const View: IOTAEditView; var FullRepaint: Boolean); override;
    procedure PaintLine(const View: IOTAEditView; LineNumber: Integer;
      const LineText: PAnsiChar; const TextWidth: Word; const LineAttributes: TOTAAttributeArray;
      const Canvas: TCanvas; const TextRect: TRect; const LineRect: TRect; const CellSize: TSize); override;
  end;

//______________________________________________________________________________________________________________________

procedure Register;

implementation

uses
    System.StrUtils
  , System.Generics.Defaults
  , System.Math
  , DelphiLint.Settings
  , System.IOUtils
  , DelphiLint.Plugin
  ;

var
  GEditorNotifier: Integer;

//______________________________________________________________________________________________________________________

procedure Register;
begin
  RegisterPackageWizard(TLintMenuItem.Create(
    'analyzeproject',
    'Analyze Project with DelphiLint',
    procedure begin
      Plugin.AnalyzeActiveFile;
    end
  ));

  GEditorNotifier := (BorlandIDEServices as IOTAEditorServices).AddNotifier(TLintEditor.Create);
end;

//______________________________________________________________________________________________________________________

constructor TLintMenuItem.Create(Name: string; Caption: string; Action: TMenuItemAction);
begin
  FName := Name;
  FCaption := Caption;
  FAction := Action;
end;

//______________________________________________________________________________________________________________________

procedure TLintMenuItem.Execute;
begin
  FAction;
end;

//______________________________________________________________________________________________________________________

function TLintMenuItem.GetIDstring: string;
begin
  Result := 'DelphiLint|' + FName;
end;

//______________________________________________________________________________________________________________________

function TLintMenuItem.GetMenuText: string;
begin
  Result := FCaption;
end;

//______________________________________________________________________________________________________________________

function TLintMenuItem.GetName: string;
begin
  Result := FName;
end;

//______________________________________________________________________________________________________________________

function TLintMenuItem.GetState: TWizardState;
begin
  Result := [wsEnabled];
end;

//______________________________________________________________________________________________________________________

constructor TLintEditor.Create;
begin
  inherited;

  // Once registered with the IDE, notifiers are reference counted
  FNotifiers := TList<TNotifierBase>.Create;
  FTrackers := TObjectList<TEditorLineTracker>.Create;
  FInitedViews := TList<IOTAEditView>.Create;

  Plugin.OnAnalysisComplete.AddListener(OnAnalysisComplete);

  Log.Info('Editor notifier created');
end;

//______________________________________________________________________________________________________________________

destructor TLintEditor.Destroy;
var
  Notifier: TNotifierBase;
begin
  for Notifier in FNotifiers do begin
    Notifier.Release;
  end;

  Plugin.OnAnalysisComplete.RemoveListener(OnAnalysisComplete);
  FreeAndNil(FTrackers);
  FreeAndNil(FNotifiers);
  FreeAndNil(FInitedViews);
  inherited;
end;

//______________________________________________________________________________________________________________________

procedure TLintEditor.EditorViewActivated(const EditWindow: INTAEditWindow; const EditView: IOTAEditView);
begin
  Log.Info('View activated...');
  if not IsViewInited(EditView) then begin
    InitView(EditView);
  end;
end;

//______________________________________________________________________________________________________________________

procedure TLintEditor.ViewNotification(const View: IOTAEditView; Operation: TOperation);
begin
  if Operation = opInsert then begin
    Log.Info('View created...');
    InitView(View);
  end;
end;

//______________________________________________________________________________________________________________________

procedure TLintEditor.InitView(const View: IOTAEditView);
var
  Tracker: TEditorLineTracker;
  Notifier: TLintView;
  NotifierIndex: Integer;
begin
  Tracker := TEditorLineTracker.Create(View.Buffer.GetEditLineTracker);
  FTrackers.Add(Tracker);
  Tracker.OnLineChanged.AddListener(OnTrackedLineChanged);
  Tracker.OnEditorClosed.AddListener(
    procedure (const Trckr: TEditorLineTracker) begin
      FTrackers.Remove(Trckr);
    end);

  Notifier := TLintView.Create;
  FNotifiers.Add(Notifier);
  NotifierIndex := View.AddNotifier(Notifier);
  Notifier.OnReleased.AddListener(
    procedure(const Notf: TNotifierBase) begin
      View.RemoveNotifier(NotifierIndex);
    end);
  Notifier.OnOwnerFreed.AddListener(
    procedure(const Notf: TNotifierBase) begin
      // Only one notifier per view so this is OK
      FNotifiers.Remove(Notf);
      FInitedViews.Remove(View);
    end);

  FInitedViews.Add(View);

  Log.Info('Initialised view for ' + View.Buffer.FileName);
end;

//______________________________________________________________________________________________________________________

function TLintEditor.IsViewInited(const View: IOTAEditView): Boolean;
begin
  Result := FInitedViews.Contains(View);
end;

//______________________________________________________________________________________________________________________

procedure TLintEditor.OnAnalysisComplete(const Issues: TArray<TLintIssue>);
var
  Tracker: TEditorLineTracker;
  FileIssues: TArray<TLintIssue>;
  Issue: TLintIssue;
begin
  Log.Info('Resetting tracking for ' + IntToStr(FTrackers.Count) + ' trackers.');

  for Tracker in FTrackers do begin
    Log.Info('Setting tracking for ' + Tracker.FilePath);
    Tracker.ClearTracking;

    FileIssues := Plugin.GetIssues(Tracker.FilePath);
    for Issue in FileIssues do begin
      Log.Info('Tracking line ' + IntToStr(Issue.Range.StartLine) + ' in ' + Issue.FilePath);
      Tracker.TrackLine(Issue.Range.StartLine);
    end;
  end;
end;

//______________________________________________________________________________________________________________________

procedure TLintEditor.OnTrackedLineChanged(const ChangedLine: TChangedLine);
begin
  Log.Info(Format('Change: %d->%d (%s)', [ChangedLine.FromLine, ChangedLine.ToLine, ChangedLine.Tracker.FilePath]));
  Plugin.UpdateIssueLine(ChangedLine.Tracker.FilePath, ChangedLine.FromLine, ChangedLine.ToLine);
end;

//______________________________________________________________________________________________________________________
//
// TLintView
//
//______________________________________________________________________________________________________________________

constructor TLintView.Create;
begin
  inherited;

  FRepaint := False;
  Plugin.OnAnalysisComplete.AddListener(OnAnalysisComplete);
end;

//______________________________________________________________________________________________________________________

destructor TLintView.Destroy;
begin
  Plugin.OnAnalysisComplete.RemoveListener(OnAnalysisComplete);
  inherited;
end;

//______________________________________________________________________________________________________________________

procedure TLintView.OnAnalysisComplete(const Issues: TArray<TLintIssue>);
begin
  FRepaint := True;
end;

//______________________________________________________________________________________________________________________

procedure TLintView.EditorIdle(const View: IOTAEditView);
begin
  if FRepaint then begin
    View.GetEditWindow.Form.Repaint;
  end;
end;

//______________________________________________________________________________________________________________________

procedure TLintView.BeginPaint(const View: IOTAEditView; var FullRepaint: Boolean);
begin
  if FRepaint then begin
    FullRepaint := True;
    FRepaint := False;
  end;
end;

//______________________________________________________________________________________________________________________

procedure TLintView.PaintLine(const View: IOTAEditView; LineNumber: Integer; const LineText: PAnsiChar;
  const TextWidth: Word; const LineAttributes: TOTAAttributeArray; const Canvas: TCanvas; const TextRect,
  LineRect: TRect; const CellSize: TSize);

  function ColumnToPx(const Col: Integer): Integer;
  begin
    Result := TextRect.Left + (Col + 1 - View.LeftColumn) * CellSize.Width;
  end;

  procedure DrawLine(const StartChar: Integer; const EndChar: Integer);
  var
    StartX: Integer;
    EndX: Integer;
  begin
    Canvas.Pen.Color := clWebGold;
    Canvas.Pen.Width := 1;

    StartX := Max(ColumnToPx(StartChar), TextRect.Left);
    EndX := Max(ColumnToPx(EndChar), TextRect.Left);

    Canvas.MoveTo(StartX, TextRect.Bottom - 1);
    Canvas.LineTo(EndX, TextRect.Bottom - 1);
  end;

  procedure DrawMessage(const Msg: string);
  begin
    Canvas.Font.Color := clWebGold;
    Canvas.Brush.Style := bsClear;
    Canvas.TextOut(LineRect.Left + (2 * CellSize.Width), LineRect.Top, '!');
    Canvas.TextOut(TextRect.Right, TextRect.Top, Msg);
  end;

var
  CurrentModule: IOTAModule;
  Issues: TArray<TLintIssue>;
  Issue: TLintIssue;
  Msg: string;
begin
  CurrentModule := (BorlandIDEServices as IOTAModuleServices).CurrentModule;
  Issues := Plugin.GetIssues(CurrentModule.FileName, LineNumber);

  if Length(Issues) > 0 then begin
    for Issue in Issues do begin
      Msg := Msg + ' - ' + Issue.Message;
      DrawLine(Issue.Range.StartLineOffset, Issue.Range.EndLineOffset);
    end;

    DrawMessage(Msg);
  end;
end;

//______________________________________________________________________________________________________________________

initialization

finalization
  (BorlandIDEServices as IOTAEditorServices).RemoveNotifier(GEditorNotifier);

end.
