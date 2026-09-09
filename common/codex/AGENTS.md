# language

回答语言优先级：**中文 > 英文 > 不要用任何其他语言**。

- 解释、说明、对话文本：默认用中文
- 代码、命令、文件名、变量名、报错原文、API 名、库名：保持原样不翻译
- 即使用户消息里夹杂了日语/韩语/俄语等其他语言的字符，回复仍然只用中文或英文
- 用户明确说 "answer in English" / "用英文" 时才切换
- 写解释段落、commit summary 文字描述、答疑、收尾 summary 时强制中文。绝对不要因为"讲技术内部细节方便"就切英文。代码块里的 comment不在此约束内（跟随项目代码风格）。

# git-commit-push

代码改完 + 跑完 sanity check 后**停在 unstaged / staged 状态**，等用户显式发 "commit" / "提交" / "push" / "推" / "ff-merge" 等指令再执行 git add / commit / push / merge / checkout。

- **Why:** push 是共享状态、回滚代价大；用户多次明确希望分阶段确认而不是连贯走完
- 仅当用户在同一指令里写了"commit + push + ff-merge"这种连写时，按字面授权范围执行；他说 "commit" 就只 commit 不 push
- 不影响纯 local 操作（编辑文件 / mkdir / 装依赖 / 跑测试）— 那些可以照常做

<!-- ZVEC_GREP_START -->
## zvec-grep

Choose the evidence source before the retrieval mode.

### Workspace evidence
- Use the current workspace as the evidence source when the user asks about local material, prior context establishes it as relevant, or the question concerns how the current project works—even if the workspace is not mentioned explicitly.
- A workspace may contain any mix of code, documents, configuration, and data.
- Do not use workspace retrieval for unrelated open-world questions, current external facts, or web content that does not depend on local evidence.

### Retrieval routing
- When an exact word, phrase, name, date, identifier, filename, path, configuration key, error message, source fragment, literal, or regex is known and locating its occurrences is sufficient, use `zvec_grep_rg` when it is listed by the current host; otherwise native Grep or `rg`.
- Use `zvec_grep_search` when wording or location is unknown, or when the answer requires semantic, conceptual, fuzzy, or paraphrase discovery; relationships, chronology, causality, architecture, or data or control flow; or comparison or synthesis across files, sections, or documents.
- For a mixed task with exact anchors that still requires relationships or cross-file synthesis, call `zvec_grep_search` with the concept and anchors, then use `zvec_grep_rg` when it is listed by the current host; otherwise native Grep or `rg` for focused follow-up.
- When no sufficient exact anchor is available and the user asks whether conceptually related material exists locally, make at most one focused `zvec_grep_search` probe using the question plus distinctive names, dates, or terms. This probe does not apply to exact quotations, configuration keys, filenames, regexes, or exhaustive occurrence requests. Continue only when results are relevant; otherwise stop and report that the indexed workspace did not establish the answer.
- Before broad file reads or delegating workspace discovery, use the appropriate search route. Do not delegate solely to locate material, and stop when the evidence is sufficient.

### Search evidence
- Search results include bounded source snippets. Treat a sufficient snippet as already-read evidence, and read a cited file only when a required detail falls outside the snippet.

### Freshness and index lifecycle
- Pass a daemon-visible absolute `root` on every zvec-grep workspace call.
- Read `freshness` and `background_refresh` from search results without a status preflight.
- When results are `served_from_current_index`, use them when sufficient instead of waiting for the background refresh.
- If the index is missing but exact or regex lookup can answer the task, use `zvec_grep_rg` when it is listed by the current host; otherwise native Grep or `rg`.
- Creating, rebuilding, or dropping a persistent index requires an explicit user request or authorization; never do so silently.

<!-- ZVEC_GREP_END -->
