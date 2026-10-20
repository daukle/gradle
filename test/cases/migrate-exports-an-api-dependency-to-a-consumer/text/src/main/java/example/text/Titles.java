package example.text;

import org.apache.commons.text.WordUtils;

public final class Titles {
  public static String title(String words) {
    return WordUtils.capitalizeFully(words);
  }
}
