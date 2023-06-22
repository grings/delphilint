/*
 * DelphiLint Server
 * Copyright (C) 2023 Integrated Application Development
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 3 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */
package au.com.integradev.delphilint.analysis;

import au.com.integradev.delphilint.analysis.TrackableWrappers.ClientTrackable;
import au.com.integradev.delphilint.sonarqube.ApiException;
import au.com.integradev.delphilint.sonarqube.ConnectedList;
import au.com.integradev.delphilint.sonarqube.SonarQubeConnection;
import au.com.integradev.delphilint.sonarqube.SonarQubeIssue;
import au.com.integradev.delphilint.sonarqube.SonarQubeUtils;
import java.nio.file.Path;
import java.util.HashSet;
import java.util.LinkedList;
import java.util.Map;
import java.util.Optional;
import java.util.Queue;
import java.util.Set;
import java.util.stream.Collectors;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import org.sonarsource.sonarlint.core.analysis.api.ActiveRule;
import org.sonarsource.sonarlint.core.analysis.api.AnalysisConfiguration;
import org.sonarsource.sonarlint.core.analysis.api.AnalysisEngineConfiguration;
import org.sonarsource.sonarlint.core.analysis.api.ClientInputFile;
import org.sonarsource.sonarlint.core.analysis.api.Issue;
import org.sonarsource.sonarlint.core.analysis.container.global.GlobalAnalysisContainer;
import org.sonarsource.sonarlint.core.analysis.container.module.ModuleContainer;
import org.sonarsource.sonarlint.core.commons.Language;
import org.sonarsource.sonarlint.core.commons.progress.ClientProgressMonitor;
import org.sonarsource.sonarlint.core.commons.progress.ProgressMonitor;
import org.sonarsource.sonarlint.core.issuetracking.Tracker;
import org.sonarsource.sonarlint.core.plugin.commons.PluginInstancesRepository;

public class DelphiAnalysisEngine implements AutoCloseable {
  private static final Logger LOG = LogManager.getLogger(DelphiAnalysisEngine.class);
  private final GlobalAnalysisContainer globalContainer;

  public DelphiAnalysisEngine(DelphiConfiguration delphiConfig) {
    var engineConfig =
        AnalysisEngineConfiguration.builder()
            .setWorkDir(Path.of(System.getProperty("java.io.tmpdir")))
            .addEnabledLanguage(Language.DELPHI)
            .setExtraProperties(
                Map.of(
                    "sonar.delphi.bds.path", delphiConfig.getBdsPath(),
                    "sonar.delphi.compiler.version", delphiConfig.getCompilerVersion()))
            .build();

    var pluginInstances =
        new PluginInstancesRepository(
            new PluginInstancesRepository.Configuration(
                Set.of(delphiConfig.getSonarDelphiJarPath()),
                engineConfig.getEnabledLanguages(),
                Optional.empty()));

    globalContainer = new GlobalAnalysisContainer(engineConfig, pluginInstances);
    globalContainer.startComponents();
    LOG.info("Analysis engine started");
  }

  private AnalysisConfiguration buildConfiguration(
      Path baseDir, Set<Path> inputFiles, SonarQubeConnection connection) throws ApiException {
    var configBuilder =
        AnalysisConfiguration.builder()
            .setBaseDir(baseDir)
            .addInputFiles(
                inputFiles.stream()
                    .map(
                        possiblyAbsolutePath -> {
                          if (possiblyAbsolutePath.isAbsolute()) {
                            return baseDir.relativize(possiblyAbsolutePath);
                          } else {
                            return possiblyAbsolutePath;
                          }
                        })
                    .map(relativePath -> new DelphiLintInputFile(baseDir, relativePath))
                    .collect(Collectors.toUnmodifiableList()));

    if (connection != null) {
      Set<ActiveRule> activeRules =
          connection.getActiveRules().stream()
              .filter(rule -> !RuleUtils.isIncompatible(rule.getRuleKey()))
              .collect(Collectors.toSet());
      configBuilder.addActiveRules(activeRules);
      LOG.info("Added {} active rules", activeRules.size());
    } else {
      // TODO: Have a local set of rules
      LOG.warn("Because there is no SonarQube connection, no rules will be active");
    }

    return configBuilder.build();
  }

  public Set<Issue> analyze(
      Path baseDir,
      Set<Path> inputFiles,
      ClientProgressMonitor progressMonitor,
      SonarQubeConnection connection)
      throws ApiException {
    LOG.info("About to analyze {} files", inputFiles.size());
    AnalysisConfiguration config = buildConfiguration(baseDir, inputFiles, connection);

    Set<Issue> issues = new HashSet<>();

    ModuleContainer moduleContainer =
        globalContainer.getModuleRegistry().createTransientContainer(config.inputFiles());
    try {
      LOG.info("Starting analysis");
      moduleContainer.analyze(config, issues::add, new ProgressMonitor(progressMonitor));
    } finally {
      moduleContainer.stopComponents();
    }

    LOG.info("Analysis finished");

    if (connection != null) {
      Set<ClientInputFile> clientInputFiles = new HashSet<>();
      config.inputFiles().iterator().forEachRemaining(clientInputFiles::add);
      issues = postProcessIssues(clientInputFiles, issues, connection);
    }

    return issues;
  }

  private Set<Issue> postProcessIssues(
      Set<ClientInputFile> inputFiles, Set<Issue> issues, SonarQubeConnection connection)
      throws ApiException {
    Queue<ClientTrackable> clientTrackables =
        SonarQubeUtils.populateIssueMessages(connection, issues).stream()
            .map(TrackableWrappers.ClientTrackable::new)
            .collect(Collectors.toCollection(LinkedList::new));
    Set<TrackableWrappers.ServerTrackable> serverTrackables = new HashSet<>();

    ConnectedList<SonarQubeIssue> resolvedIssues = connection.getResolvedIssues(inputFiles);
    for (SonarQubeIssue resolvedIssue : resolvedIssues) {
      serverTrackables.add(new TrackableWrappers.ServerTrackable(resolvedIssue));
    }

    Tracker<TrackableWrappers.ClientTrackable, TrackableWrappers.ServerTrackable> tracker =
        new Tracker<>();
    var tracking = tracker.track(() -> clientTrackables, () -> serverTrackables);

    Set<Issue> returnIssues = new HashSet<>();
    tracking
        .getUnmatchedRaws()
        .iterator()
        .forEachRemaining(trackable -> returnIssues.add(trackable.getClientObject()));

    LOG.info(
        "{}/{} issues matched with resolved server issues and discarded",
        issues.size() - returnIssues.size(),
        issues.size());

    return returnIssues;
  }

  @Override
  public void close() {
    globalContainer.stopComponents();
    LOG.info("Analysis engine closed");
  }
}
