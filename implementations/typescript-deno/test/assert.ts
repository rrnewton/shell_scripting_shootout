export function assert(
  condition: boolean,
  message = "assertion failed",
): asserts condition {
  if (!condition) throw new Error(message);
}

export function assertEquals(actual: unknown, expected: unknown): void {
  const actualText = JSON.stringify(actual);
  const expectedText = JSON.stringify(expected);
  if (actualText !== expectedText) {
    throw new Error(
      `values differ\nexpected: ${expectedText}\nactual:   ${actualText}`,
    );
  }
}

export function assertStringIncludes(actual: string, expected: string): void {
  if (!actual.includes(expected)) {
    throw new Error(
      `${JSON.stringify(actual)} does not include ${JSON.stringify(expected)}`,
    );
  }
}

export function assertThrows(fn: () => unknown, expected: string): void {
  try {
    fn();
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    assertStringIncludes(message, expected);
    return;
  }
  throw new Error(
    `expected function to throw an error containing ${
      JSON.stringify(expected)
    }`,
  );
}
