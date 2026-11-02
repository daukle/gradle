package com.example.logic;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.gradle.api.Plugin;
import org.gradle.api.Project;

public final class LevelPlugin implements Plugin<Project> {
  public static class LevelExtension {
    private List<String> tags = new ArrayList<>();
    private Map<String, Object> options = new LinkedHashMap<>();
    private final Map<String, String> labels = new LinkedHashMap<>();
    private final List<String> steps = new ArrayList<>();

    public LevelExtension() {
      labels.put("given", "by the plugin");
      steps.add("first");
    }

    public List<String> getTags() {
      return tags;
    }

    public void setTags(List<String> tags) {
      this.tags = tags;
    }

    public Map<String, Object> getOptions() {
      return options;
    }

    public void setOptions(Map<String, Object> options) {
      this.options = options;
    }

    public Map<String, String> getLabels() {
      return labels;
    }

    public List<String> getSteps() {
      return steps;
    }
  }

  @Override
  public void apply(Project project) {
    project.getExtensions().create("level", LevelExtension.class);
  }
}
