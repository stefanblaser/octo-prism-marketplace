# OCTO Prism Marketplace

Public package registry for the [OCTO Prism](https://github.com/stefanblaser/OctoPrism) DocType Marketplace.

Each directory under `packages/` contains a single `package.json` that defines a ready-to-use document type — fields, optional tables, and an extraction-strategy hint. Prism Studio consumes the top-level `catalog.json` index to render its browse/install UI.

## Structure

```
catalog.json              # auto-generated index consumed by Studio
packages/
├── de.invoice/
│   └── package.json
├── ch.payslip/
│   └── package.json
└── generic.receipt/
    └── package.json
.github/workflows/
└── regenerate-catalog.yml  # regenerates catalog.json on merge to main
```

## Package format

The authoritative reference is the design spec in the Prism repo: [`docs/superpowers/specs/2026-04-09-doctype-marketplace-design.md`](https://github.com/stefanblaser/OctoPrism/blob/master/docs/superpowers/specs/2026-04-09-doctype-marketplace-design.md) §3.

Required fields: `packageId`, `name`, `description`, `version`, `language`, `fields[]`.

`dataType` values are one of: `String | Integer | Decimal | Date | Boolean`. Currency amounts use `Decimal` plus a `format` hint (e.g. `"format": "€"`).

### Naming convention

- **Region-specific packages:** `<region>.<category>` → `de.invoice`, `ch.payslip`, `at.invoice`, `us.w2`
- **Region-agnostic templates:** `generic.<category>` → `generic.receipt`, `generic.contract`

Package IDs must be globally unique, lowercase, and dot-separated. They should stay stable across version bumps — never rename a package's `packageId`, only bump its `version` field.

## Contributing

1. Fork the repo.
2. Add or update a package under `packages/<packageId>/package.json`.
3. Open a PR against `main`. The `catalog.json` regenerates automatically after your PR is merged.

## License

Content in this repository is offered under MIT. Packages contributed by the community are provided as-is — verify extraction quality against your own documents before deploying to production.
