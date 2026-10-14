package example.logic;

import org.gradle.api.Plugin;
import org.gradle.api.Project;

public final class HelloPlugin implements Plugin<Project> {
  public void apply(Project project) {
    project.getTasks().register("hello", task ->
        task.doLast(ignored -> System.out.println("hello from an included build")));
  }
}
