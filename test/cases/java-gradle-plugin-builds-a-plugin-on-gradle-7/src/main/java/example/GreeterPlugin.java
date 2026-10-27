package example;

import org.gradle.api.Plugin;
import org.gradle.api.Project;

public final class GreeterPlugin implements Plugin<Project> {
  @Override
  public void apply(Project project) {
    project.getTasks().register("greet", task -> task.doLast(action -> System.out.println("hello")));
  }
}
