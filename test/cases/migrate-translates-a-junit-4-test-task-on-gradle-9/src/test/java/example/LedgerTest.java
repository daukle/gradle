package example;

import static org.junit.Assert.assertNotNull;

import org.junit.Test;

public class LedgerTest {
  @Test
  public void exists() {
    assertNotNull(Ledger.class);
  }
}
