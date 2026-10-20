package example;

import com.google.common.base.Joiner;

public final class Lister {
  public static String list(String... items) {
    return Joiner.on(", ").join(items);
  }
}
