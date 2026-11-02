package com.example.logic;

import java.util.LinkedHashMap;
import java.util.Map;
import org.gradle.api.Plugin;
import org.gradle.api.initialization.Settings;

public final class MarkingPlugin implements Plugin<Settings> {
  public static final class Mark {
    final String path;

    Mark(String path) {
      this.path = path;
    }
  }

  public static class MarkingExtension {
    private Map<String, Mark> marksByPath = new LinkedHashMap<>();
    private String prefix;

    public String getPrefix() {
      return prefix;
    }

    public void setPrefix(String prefix) {
      this.prefix = prefix;
    }

    public void mark(String path) {
      marksByPath.put(path, new Mark(path));
    }

    boolean isMarked(String path) {
      return marksByPath.containsKey(path);
    }
  }

  @Override
  public void apply(Settings settings) {
    MarkingExtension marking = new MarkingExtension();
    settings.getExtensions().add("marking", marking);
    settings.getGradle().afterProject(project -> {
      if (marking.isMarked(project.getPath())) project.getTasks().register("marked");
    });
  }
}
