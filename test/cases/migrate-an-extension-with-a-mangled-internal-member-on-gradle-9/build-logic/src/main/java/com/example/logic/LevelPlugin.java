package com.example.logic;

import org.gradle.api.Plugin;
import org.gradle.api.Project;

public final class LevelPlugin implements Plugin<Project> {
  public static class LevelExtension {
    private final Project owner;
    private String label = "default";
    private String hidden = "internal";

    public LevelExtension(Project owner) {
      this.owner = owner;
    }

    public String getLabel() {
      return label;
    }

    public void setLabel(String label) {
      this.label = label;
    }

    public String getHidden$logic() {
      return hidden;
    }

    public void setHidden$logic(String hidden) {
      this.hidden = hidden;
    }

    public Project getOwner$logic() {
      return owner;
    }
  }

  @Override
  public void apply(Project project) {
    project.getExtensions().create("level", LevelExtension.class, project);
  }
}
