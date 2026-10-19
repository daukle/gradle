package example.app;

import example.text.Titles;
import org.apache.commons.lang3.StringUtils;

public final class Banner {
  public static String banner(String words) {
    return StringUtils.center(Titles.title(words), 40, '*');
  }
}
