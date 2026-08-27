# `docs/diagrams/`

Diagrams live **inline in the documents**, as Mermaid, rather than as
image files here.

## Why

A `.png` in a repository is a diagram that stops matching the code the
first time someone changes the code. Mermaid in the Markdown is
reviewed in the same pull request as the change it describes, renders
natively on GitHub, and shows a meaningful diff.

## Where they are

| Diagram | Document |
|---|---|
| The whole path, commit to running machines | [`../ARCHITECTURE.md`](../ARCHITECTURE.md) |
| Boot dispatch state machine | [`../ARCHITECTURE.md`](../ARCHITECTURE.md) |
| Network topology (ASCII) | [`../ARCHITECTURE.md`](../ARCHITECTURE.md) |
| Configuration flow (ASCII) | [`../ARCHITECTURE.md`](../ARCHITECTURE.md) |
| GitOps sequence | [`../GITOPS-WORKFLOW.md`](../GITOPS-WORKFLOW.md) |
| Component overview | [`../../README.md`](../../README.md) |
| The boot chain, end to end | [`../../pxe/README.md`](../../pxe/README.md) |

## Exporting one

For a slide deck or a document that cannot render Mermaid:

```bash
npm install -g @mermaid-js/mermaid-cli
# extract the fenced block, then:
mmdc -i diagram.mmd -o diagram.png -w 2400 -b transparent
```

Put the result wherever it is being used, **not here**. An exported copy
in the repository is a second thing to keep in step, and it will not
be kept in step.

## Adding one

Use Mermaid where it shows a mechanism — a sequence, a state machine, a
decision. Use an ASCII block where alignment carries the meaning, such
as a network layout or a directory tree; those render identically
everywhere and never fail to load.

If a diagram would only restate a list, write the list.
