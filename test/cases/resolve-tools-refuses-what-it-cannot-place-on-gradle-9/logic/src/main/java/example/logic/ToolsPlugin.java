package example.logic;

import java.util.Map;
import java.util.function.Consumer;
import org.gradle.api.Plugin;
import org.gradle.api.Project;
import org.gradle.api.artifacts.ExternalModuleDependency;

public final class ToolsPlugin implements Plugin<Project> {
  public void apply(Project project) {
    withDefault(project, "tool-runner", "org.example:runner:1.0", dependency -> { });
    withDefault(project, "classified", "org.example:tool:1.0:native", dependency -> { });
    withDefault(project, "excluded", "org.example:other:1.0",
        dependency -> dependency.exclude(Map.of("group", "org.unwanted")));
  }

  private static void withDefault(Project project, String name, String coordinate,
                                  Consumer<ExternalModuleDependency> shape) {
    project.getConfigurations().create(name).defaultDependencies(dependencies -> {
      ExternalModuleDependency dependency =
          (ExternalModuleDependency) project.getDependencies().create(coordinate);
      shape.accept(dependency);
      dependencies.add(dependency);
    });
  }
}
