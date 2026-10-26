# iOS 独立检查与 CI

`ios/Tests/run_checks.py` 将真实生产源码与合成测试数据一起编译，运行已登记的 39 项 Swift 检查及其参数分支。新增顶层检查未登记会直接失败。它创建并最终删除独立模拟器，部分检查在 macOS 主机运行；不构建、安装或启动 Tincall App。

## 运行

在仓库根目录执行。需要 Xcode、iOS 26 或以上模拟器运行时、Python 3 和 Node.js；SQL 检查另需已运行的 Docker 与 `postgres:18-alpine` 镜像。LAME 使用仓库中的本地包。

```sh
# 查看检查及运行平台
python3 ios/Tests/run_checks.py --list

# 运行全部检查，或仅选择与改动相关的检查
python3 ios/Tests/run_checks.py --output /absolute/path/to/check-results
python3 ios/Tests/run_checks.py MCPSummaryUploadChecks --output /absolute/path/to/summary-results

# 导出生产部署 SQL，在本地 PostgreSQL 中验证
python3 ios/Tests/run_checks.py SupabaseDeploymentChecks --output /absolute/path/to/deployment-results
docker pull postgres:18-alpine
python3 ios/Tests/SupabaseDeploymentSQLChecks.py /absolute/path/to/deployment-results/sql-transactions
```

## 结果状态

`.github/workflows/build.yml` 的 `ios-checks` 执行全部 Swift 检查并保留日志、`results.json` 与 SQL 产物；`ios-deployment-sql` 在本地 PostgreSQL 中执行导出的生产事务，不部署到 Supabase。

- `passed`：检查通过。
- `partial`：已运行分支通过，仍有下列未覆盖内容。
- `failed`：编译、断言、进程或超时失败；命令返回非零。
- `skipped`：未执行，不计为通过；当前没有登记跳过项。

## 四项覆盖边界

| 检查 | 覆盖边界 |
| --- | --- |
| `SpeechPlaybackChecks` | macOS 队列、分段及状态检查；未运行 iOS 回声消除判断与 AVAudioSession 路由。 |
| `CallAccessStoreChecks` | 源码版权益与试用边界；未执行购买、恢复、退款及 Ask to Buy 交易。 |
| `SystemCallContactChecks` | URL／Intent 解析与拒绝规则；未执行需 Contacts 授权的 `--store` 保存及读回。 |
| `SupabaseDeploymentChecks` | 非商店部署规则与生产 SQL 导出；未编译执行 `TINCALL_APP_STORE --push-only` 分支。 |

真实通话、蓝牙音频、Production APNs、商店交易和线上服务仍需在对应设备或环境测试。
