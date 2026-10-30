package com.example.logic;

import org.gradle.api.Plugin;
import org.gradle.api.Project;
import org.gradle.api.file.ConfigurableFileCollection;

public final class LevelPlugin implements Plugin<Project> {
  public static class LevelExtension {
    private final ConfigurableFileCollection inputs;

    public LevelExtension(Project project) {
      this.inputs = project.getObjects().fileCollection();
    }

    public ConfigurableFileCollection getInputs() {
      return inputs;
    }
  }

  @Override
  public void apply(Project project) {
    project.getExtensions().create("level", LevelExtension.class, project);
  }
}
