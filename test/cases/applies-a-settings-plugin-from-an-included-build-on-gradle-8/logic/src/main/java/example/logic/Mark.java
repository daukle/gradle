package example.logic;

import org.gradle.api.Plugin;
import org.gradle.api.initialization.Settings;

public final class Mark implements Plugin<Settings> {
  public void apply(Settings settings) {
    System.out.println("settings plugin from an included build applied");
  }
}
