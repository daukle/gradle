package example.logic;

import org.gradle.api.Plugin;
import org.gradle.api.Project;

public final class GsonPlugin implements Plugin<Project> {
  public void apply(Project project) {
    project.getPlugins().withId("java", ignored ->
        project.getDependencies().add("implementation", "com.google.code.gson:gson:2.10.1"));
  }
}
