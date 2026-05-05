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

@RTK.md
