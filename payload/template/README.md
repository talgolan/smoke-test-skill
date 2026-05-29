# {{TOPIC}} smoke runner

Created by `/smoke-add {{TOPIC}}` (or `/smoke-init` if this was your first runner).

## Run

```sh
./run.zsh             # run all auto sections
./run.zsh --list      # show sections, with [manual] tags
./run.zsh 01          # run §1 only
./run.zsh --all       # include MANUAL_SECTIONS
```

Output goes to `logs/run-<timestamp>.log` and stdout.

## Add a new section

1. Create `steps/NN-<slug>.zsh` (NN sequential from existing).
2. Append `"NN-<slug>"` to `ALL_SECTIONS` in `run.zsh`.
3. Read `../AUTHORING_GUIDE.md` before writing the body — every rule there is real.
4. Run the grep gate from `../AUTHORING_GUIDE.md` before committing.

## File layout

```
{{TOPIC}}/
├── README.md           # this file
├── run.zsh             # controller
├── steps/
│   └── NN-<slug>.zsh   # one per section
└── logs/               # run-<ts>.log + <NN>-<slug>-pane.log
```

`SUT_BIN`, `SUT_REPO`, `BUILD_CMD`, etc. come from `../.smokerc` (this runner's parent install dir).
