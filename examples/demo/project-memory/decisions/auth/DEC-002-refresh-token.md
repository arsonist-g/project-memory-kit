---
id: DEC-002
title: 刷新令牌用旋转式，不用长效令牌
status: accepted
date: 2026-10-13
summary: 刷新令牌一次性使用，用后即换新，旧的进黑名单
tags: [auth, token, security]
supersedes: []
superseded-by: []
evidence: [research/auth/2026-10-13-token-strategy]
---

## 决策

刷新令牌一次性使用，每次刷新都换发新的，旧的立即失效并进黑名单。

## 背景

长效刷新令牌一旦泄露，攻击窗口等于令牌有效期。

## 后果

多一次存储与一次网络往返，换来可检测的令牌盗用（旧令牌被再次使用即告警）。
