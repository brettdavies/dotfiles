import { defineHexConfig } from "@hex/commands"

export default defineHexConfig({
  transformations: {
    // Parakeet writes a spoken "dot files" as ".files", often glued to the word before ("the.files"), and the span
    // holds a ".", so vocabulary rescoring skips it as a path. Paths such as "~/.files-list" are left alone.
    dotfiles: {
      name: "dotfiles",
      description: "Write a spoken \"dot files\" as dotfiles",
      transform: (text) =>
        text
          .replace(/(?<![/~.-])([A-Za-z0-9])?\.files\b(?![-/.])/gi, (_, before) => (before ? `${before} ` : "") + "dotfiles")
          .replace(/\bdot files\b/gi, "dotfiles"),
    },
  },
})
