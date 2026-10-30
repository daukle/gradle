package com.example.logic;

import org.gradle.api.Plugin;
import org.gradle.api.Project;

public final class LevelPlugin implements Plugin<Project> {
  public static class LevelExtension {
    private String label = "default";
    private final View view = new View();

    public String getLabel() {
      return label;
    }

    public void setLabel(String label) {
      this.label = label;
    }

    public View getView() {
      return view;
    }

    public final class View {
      public String getLabel() {
        return label;
      }

      public void setLabel(String label) {
        LevelExtension.this.label = label;
      }
    }
  }

  @Override
  public void apply(Project project) {
    project.getExtensions().create("level", LevelExtension.class);
  }
}
