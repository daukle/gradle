package com.example.logic;

import org.gradle.api.JavaVersion;
import org.gradle.api.Plugin;
import org.gradle.api.Project;

public final class LevelPlugin implements Plugin<Project> {
  public static class LevelExtension {
    private JavaVersion version = JavaVersion.VERSION_17;

    public JavaVersion getVersion() {
      return version;
    }

    public void setVersion(JavaVersion version) {
      this.version = version;
    }
  }

  @Override
  public void apply(Project project) {
    project.getExtensions().create("level", LevelExtension.class);
  }
}
