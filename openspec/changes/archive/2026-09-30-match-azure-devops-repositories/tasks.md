## 1. Tests

- [x] 1.1 Azure repository resolved from `{org}/{project}/{repo}` and from `{project}/{repo}`
- [x] 1.2 Same short name in two Azure projects fails as ambiguous and starts no scan
- [x] 1.3 GitHub resolution unchanged: one `repositories` query, owner match, fallback kept

## 2. Implementation

- [x] 2.1 Azure candidate query and matching in `resolve_repository`
- [x] 2.2 Ambiguity failure listing the candidates

## 3. Documentation

- [x] 3.1 Azure forms of `repository` in `docs/reference.md` and `docs/configuration.md`
