import { defineConfig } from "vitest/config"

export default defineConfig({
  test: {
    include: ["../tests/unit/mcp-*.test.js"],
    testTimeout: 30000,
  },
})
