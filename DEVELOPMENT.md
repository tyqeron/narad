# Development journal

Each milestone is a separate Git commit. Planning documents are preserved in
the first commit. `git log --reverse --oneline` shows the development sequence.

## 1. Workspace foundation

- Rust workspace split into portable `narad-core` and the `narad` daemon/CLI.
- Protocol v1; control, file and media responsibilities remain separate.
- Flutter desktop client planned first; Android/iOS native daemon embedding and
  platform keystores require device work before those targets can ship.
- Private state and generated build output are excluded from Git.

## Validation policy

Run formatting, relevant behavioral tests, and lint checks at milestones.
Use two actual daemon instances for integration tests, including negative trust,
permission and recovery cases. Record unsupported or untested behavior honestly.
