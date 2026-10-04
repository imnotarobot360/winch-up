import { defineConfig } from "vitest/config";
import { fileURLToPath } from "node:url";

export default defineConfig({
  // Next compiles JSX with the automatic runtime; esbuild defaults to the classic one, which
  // needs React in scope and fails with "React is not defined".
  esbuild: { jsx: "automatic" },

  test: {
    // Pure logic, plus component tests that opt into jsdom with a file-level
    // @vitest-environment comment. Nothing here touches a database or the network.
    // scripts/ is in here for check-db-url.test.ts: the migrate job has no Node step, so
    // that checker has to be shell, and one tested implementation beats a TypeScript twin.
    include: ["src/**/*.test.ts", "src/**/*.test.tsx", "scripts/**/*.test.ts"],
    environment: "node",
  },
  resolve: {
    alias: {
      "@": fileURLToPath(new URL("./src", import.meta.url)),
    },
  },
});
