package com.example.logic;

import org.gradle.api.Plugin;
import org.gradle.api.Project;
import org.gradle.api.file.FileCollection;
import org.gradle.api.tasks.SourceSetContainer;

public final class LevelPlugin implements Plugin<Project> {
  public static class LevelExtension {
    private final Project project;

    public LevelExtension(Project project) {
      this.project = project;
    }

    public FileCollection getOutputs() {
      SourceSetContainer sets = project.getExtensions().getByType(SourceSetContainer.class);
      return sets.getByName("main").getOutput();
    }

    public FileCollection getLibraries() {
      return project.files(project.getConfigurations().getByName("runtimeClasspath"));
    }
  }

  @Override
  public void apply(Project project) {
    project.getExtensions().create("level", LevelExtension.class, project);
  }
}
