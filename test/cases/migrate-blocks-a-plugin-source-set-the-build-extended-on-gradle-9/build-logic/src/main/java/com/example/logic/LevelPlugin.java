package com.example.logic;

import org.gradle.api.Plugin;
import org.gradle.api.Project;
import org.gradle.api.file.SourceDirectorySet;

public final class LevelPlugin implements Plugin<Project> {
  public static class LevelExtension {
    private final SourceDirectorySet sources;

    public LevelExtension(Project project) {
      this.sources = project.getObjects().sourceDirectorySet("level", "level sources");
      this.sources.srcDir("src/a");
    }

    public SourceDirectorySet getSources() {
      return sources;
    }
  }

  @Override
  public void apply(Project project) {
    project.getExtensions().create("level", LevelExtension.class, project);
  }
}
