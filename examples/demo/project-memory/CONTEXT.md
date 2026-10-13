<!-- GENERATED — 由 pmem 生成，请勿手改 -->
> 更新于 2026-10-13 · HEAD ??????
> 决策 2 条 / 2 个域 · 开放问题 1 条 · 调研报告 2 份

<!-- HANDWRITTEN:BEGIN -->
# 项目一句话

示例项目：一个演示 project-memory 形状的最小项目，内容都是编的。

# 当前状态

- 鉴权重构进行中；刷新令牌旋转（DEC-002）已定但未实现。
- 存储选型已定 PostgreSQL（DEC-001）。
- 多租户隔离方式未决（Q-001），未决前不要动 schema。

# 下次第一件事

实现 DEC-002 的旋转式刷新令牌与黑名单。

# 指针

- 设计：`spec/`
- 证据：`research/auth/2026-10-13-token-strategy`
<!-- HANDWRITTEN:END -->
