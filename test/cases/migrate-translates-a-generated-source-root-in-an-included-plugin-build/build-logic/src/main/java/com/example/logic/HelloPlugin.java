package com.example.logic;

import org.gradle.api.Plugin;
import org.gradle.api.Project;

public final class HelloPlugin implements Plugin<Project> {
  @Override
  public void apply(Project project) {
    project.getTasks().register("hello", task -> task.doLast(ignored -> System.out.println(Config.GREETING)));
  }
}
