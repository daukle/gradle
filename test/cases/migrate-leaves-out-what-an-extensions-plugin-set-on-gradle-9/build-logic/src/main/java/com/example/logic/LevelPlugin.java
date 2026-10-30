package com.example.logic;

import org.gradle.api.Plugin;
import org.gradle.api.Project;

public final class LevelPlugin implements Plugin<Project> {
  public static final class Handle {
  }

  public static class LevelExtension {
    private String label = "default";
    private int count = 3;
    private Handle handle = new Handle();

    public String getLabel() {
      return label;
    }

    public void setLabel(String label) {
      this.label = label;
    }

    public int getCount() {
      return count;
    }

    public void setCount(int count) {
      this.count = count;
    }

    public Handle getHandle() {
      return handle;
    }

    public void setHandle(Handle handle) {
      this.handle = handle;
    }
  }

  @Override
  public void apply(Project project) {
    project.getExtensions().create("level", LevelExtension.class);
  }
}
