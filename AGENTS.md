# agent-network-skill

通过 CommHub MCP 完成「派任务 → 干活 → 回报 → 验收」闭环的统一协议技能，
供 agent-network 项目的规划者（opencode/指挥室）与工人（pi/执行者）共用。

## 用途

一份协议、两个角色：任何读取本目录的 agent 都能知道自己在闭环里该调哪些
MCP 工具、按什么顺序、参数有什么硬约束。

## 触发

- 派任务 / 收任务 / 验收 / 查 inbox
- `alias_not_found`、任务卡在 acked/running、`report_completion` 后状态没变
- 跨机协作、双目录（两个 clone）任务分工

## 内容

完整的连接前提、角色流程、状态机、参数铁律与 Gotchas 见
[SKILL.md](SKILL.md)。安装与发现方式见 [README.md](README.md)。
