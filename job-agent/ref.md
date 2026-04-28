# ai-pipeline
在容器里执行无人监管模式的[qwen code](https://qwenlm.github.io/qwen-code-docs/zh/users/overview/)，使用的是[yolo](https://qwenlm.github.io/qwen-code-docs/zh/users/features/approval-mode/)模式，即✅ 自动批准。

启动的脚本大致为
```shell
    # 执行任务
    timeout ${ISC_CLAUDE_CODE_TIMEOUT:-"1800"} \
        \qwen --debug --output-format stream-json --yolo -p "工作目录为: /opt/cloud/data/claude-code/ , ${ISC_CLAUDE_CODE_PROMPT}" \
        2>&1 | tee /opt/cloud/logs/claude-code/result.txt | _fmt_stream | tee /opt/cloud/logs/claude-code/pretty.txt || true
```

ISC_CLAUDE_CODE_PROMPT示例：

```
                代码仓库为: `git clone http://@100.94.167.151:3020/xdm/xdm-f-core-5.git`;
                必须使用HTTP方式克隆仓库, 禁止使用SSH方式克隆仓库, 如果重试10次仍然克隆仓库失败, 则结束本次任务;
                执行代码仓库prompt.md文件中的指令;
                鼓励使用sudo提权执行高权限操作例如安装软件;
```


# prompt.md示例
```
# Qwen Code 指令
- 使用 **JUnit5 + Mockito** 为这个 Maven 工程按模块补充 Java 类中方法的 UT。
- **技术栈对齐**：当前环境为 **JDK 17 + Spring Boot 3**。必须使用 `jakarta.*` 包名（严禁使用 `javax.*`），断言优先使用 **AssertJ** (`assertThat`)。
- 补充 UT 的粒度是 Java 类的方法，优先覆盖逻辑复杂的业务方法。
- 必须按照 prompt.md 文件中的开发流程完成新版本的开发。
- 只为 **rdm-micservicetemplate/mstemplate.applicationSync**模块编写单元测试

# 注意事项
- prompt.md 文件用于下达指令给 Qwen Code, 禁止 AI 修改 prompt.md 文件。
- 隐私秘钥等文件禁止上传到 Git 仓库。
- 授权 Qwen Code 自动执行命令和计划, 无需批准确认。
- 必须使用 `dev` 分支开发新版本。
- `git` 命令必须在代码仓目录下执行。
- 首个版本号必须从 0.1.0 开始。
- **复杂度红线**：每个新版本 (MINOR) 最多补充 5 个方法，但**严禁**连续两个版本仅补充简单方法（如 Getter/Setter、单行 Return 或无逻辑跳转的方法）。
- 每个 MINOR 版本必须包含至少一个**圈复杂度 (Cyclomatic Complexity) > 5** 或代码行数 > 20 行的方法。
- 禁止为枚举类和 POJO/DTO 类补充 UT。
- 禁止修改 `src/main/java` 下的源码。
- 除非修复编译报错和 UT 报错, 否则禁止修改 Git 远程仓库中已有的 UT 测试类文件。
- 每次任务都必须新建 UT 测试类来补充 Java 方法的 UT, 如果新建的 UT 测试类和已有的文件同名, 可以使用序号命名, 例如 `XXX2Test`, `XXX3Test`。
- 典型的 UT 测试用例参考：`adapter/xdm-f-security/xdm-f-security-wsf/src/test/java/com/huawei/iit/sdk/common/wsf/csrf/error/CSRFAccessDeniedHandlerTest.java`。
- 由于代码量较大, 构建命令需要10分钟左右才能执行完, 可以在构建命令执行的同时做一些其他耗时较短的工作,鼓励使用subagent或并行模式

# 单测设计指南（每个方法必须做到）
- **正常路径**：至少 1 个 ，覆盖主要分支。
- **异常路径**：必须覆盖外部依赖抛出异常、非法参数等情况，使用 `assertThrows`。
- **边界与 null**：对容器/集合/对象参数考虑空值、边界值。
- **Mock 验证**：对关键 Mock 对象使用 `verify` 确认调用次数和参数。
- **中间状态断言**：使用 `ArgumentCaptor` 等捕获复杂参数并断言内部字段。
- **注释要求**：每个 mock setup 上方用简体中文注释说明“模拟 xxx 行为，因为 xxx”。
- 禁止对VO类、枚举类、Entity类编写单元测试

# 开发流程

每次任务的执行遵循新版本迭代开发全流程, 使用小步快跑的策略, 及时提交和推送代码到 Git 仓库。

## **规划与准备 (Planning)**

在写代码之前，先明确新版本的目标。

- **扫描与识别**：使用工具或搜索命令扫描目标模块，识别出含有业务逻辑（if, switch, for, stream）最多的 Service 类。
- **创建或更新项目规划**：根据任务分解，在 `plan.md` 中更新版本规划。
- **确定新版本需求范围原则**：按以下优先级顺序规划：
  - 如果构建失败（命令见下文），则必须立即规划一个 **PATCH** 版本修复报错。
  - 如果 `issues.md` 中有未关闭的 issue，则必须立即规划一个 **PATCH** 版本修复。
  - 正常情况下，开发 `plan.md` 中未实现的 **MINOR** 版本。
- **难点申明**：在 `plan.md` 中简述本版本测试方法的逻辑难点（如：需要模拟分布式锁、处理多层嵌套对象、Mock 复杂 JSON 响应等），证明已挑选高价值任务。

## **开发与测试 (Development & Testing)**

- **需求开发**：完成规划的新版本需求清单。
- **测试用例验证**：确保所有 UT 用例测试通过。使用 JUnit 5 语法（如 `assertThrows`），禁止使用 JUnit 4。
- **构建通过**：确保构建通过 `mvn clean package -am -T1C -DskipTests=true -Dmaven.compiler.fork=true -U -B -gs settings.xml -s settings.xml`。
- **提交代码**：每个 UT 文件单独提交。**Commit 信息必须包含具体的方法名**，格式：`test(<模块>): 为 <类名>.<方法名> 补充 UT`。

## **版本发布**
- 使用新版本的版本号创建 Git Tag 并推送到 Git 仓库。

## **文档完善**
- 在 `plan.md` 中更新进展。仓库介绍更新到 `README.md`。

## **问题闭环**
- 在 `issues.md` 中关闭已解决的 issue。

# 设计规范
- 最小化改动。
- 修改处添加准确易懂的简体中文日志，说明 Mock 的核心逻辑。

# Git 提交规范
- **严格禁止**：包含任何 AI 生成的文字提示。
- **格式标准**：采用 Conventional Commits 格式 `<类型>(<范围>): <主题>`。
- **语言**：必须以简体中文为主。

# 版本号规范
- **MAJOR**: 重大不兼容。
- **MINOR**: 新功能（新 UT 覆盖），向下兼容。
- **PATCH**: 修复构建、修复原有 UT 或代码重构。

# 技能中心(Skills)
- 模块 UT 运行：`mvn clean test -pl 模块名称 -am -U -B -gs settings.xml -s settings.xml`
- 全工程 UT 运行：`mvn clean test -U -B -gs settings.xml -s settings.xml`
```

# 完整的一个jobyml示例

```yml
kind: ConfigMap
apiVersion: v1
metadata:
  name: xdm-f-core-file
  namespace: default
data:
  "run.sh": |-
    #!/bin/bash

    set -ex

    # 证书配置
    curl -k -O https://cmc-nkg-artifactory.cmc.tools.huawei.com/artifactory/cmc-software-release/Service%20CM/AbCert/latest.version/abcert
    chmod +x abcert
    sudo ./abcert install

    # 读取CA证书并写入系统
    mkdir -pv /opt/cloud/security/cert/ca
    counter="0"
    find /opt/cloud/security/cert/ca -type f -print0 | while IFS= read -r -d '' file; do
        counter=$((counter + 1))
        #sudo cat ${file} >>/etc/pki/tls/certs/ca-bundle.crt
        #sudo echo "" >>/etc/pki/tls/certs/ca-bundle.crt
        sudo ${JAVA_HOME}/bin/keytool -importcert -alias "ca-${counter}" -file ${file} -keystore ${JAVA_HOME}/lib/security/cacerts -storepass changeit -noprompt
    done

    _fmt_stream() {
        # 仅调用 Python 脚本进行格式化，输出到 stdout
        # 确保 python 使用非缓冲模式 (-u)，以便 tee 能实时捕获
        python3 -u "/opt/cloud/bin/fmt_stream.py"
    }

    # 数据目录初始化
    mkdir -pv /opt/cloud/data/claude-code/ /opt/cloud/logs/claude-code/

    # 清空输出目录
    rm -rf /opt/cloud/data/claude-code/*

    # 工作目录
    cd /opt/cloud/data/claude-code/

    if [ -n "${GH_TOKEN}" ]; then
        echo "${GH_TOKEN}" | gh auth login --with-token || true
    fi

    # 设置全局用户名
    git config --global user.name "qwen-code"
    # 设置全局邮箱
    git config --global user.email "noreply@qwen-code.com"

    # 检查版本
    \qwen --version

    # 执行任务
    timeout ${ISC_CLAUDE_CODE_TIMEOUT:-"1800"} \
        \qwen --debug --output-format stream-json --yolo -p "工作目录为: /opt/cloud/data/claude-code/ , ${ISC_CLAUDE_CODE_PROMPT}" \
        2>&1 | tee /opt/cloud/logs/claude-code/result.txt | _fmt_stream | tee /opt/cloud/logs/claude-code/pretty.txt || true

    # 获取管道中第一个命令 (timeout) 的退出码
    if [ "${PIPESTATUS[0]}" -eq 124 ]; then
        echo "⚠️ Claude Code 执行超时, 强制结束"
    fi

    # 打印结果
    tail -n 1 /opt/cloud/logs/claude-code/result.txt | jq -r '.result' || true

    # 打包并压缩
    cd /opt/cloud/data/claude-code/
    ls -alh /opt/cloud/data/
    rm -rf /opt/cloud/data/* || true
    rm -rf /opt/cloud/bin/* || true

    ls -alh /opt/cloud/data/

    if [ -n "${ISC_SLEEP_TIME}" ]; then
        sleep ${ISC_SLEEP_TIME}s
    fi

  "settings.json": |-
    {
      "model": {
        "generationConfig": {
          "timeout": 600000,
          "contextWindowSize": 168000,
          "enableCacheControl": true
        }
      }
    }
---

apiVersion: batch/v1
kind: Job
metadata:
  name: xdm-f-core-service
  namespace: default
spec:
  completions: 20
  backoffLimit: 0
  parallelism: 1
  template:
    spec:
      containers:
        - name: xdm-f-core-service
          image: swr.cn-north-5.myhuaweicloud.com/token/gsc-tool-image:qwen-code-26.2.x_20260417_173923_d16de7f-x86_64
          imagePullPolicy: IfNotPresent
          command:
            - /bin/bash
          args:
            - -c
            - 'sh /opt/cloud/bin/run.sh'
          env:
            - name: "OPENAI_BASE_URL"
              value: "http://10.58.236.242:4000/v1"
            - name: "OPENAI_API_KEY"
              value: "sk-1234"
            - name: "OPENAI_MODEL"
              value: "maas-glm-5-aliyun-codeagent"
            - name: "ISC_CLAUDE_CODE_PROMPT"
              value: |
                代码仓库为: `git clone http://100.94.167.151:3020/xdm/xdm-f-core-1.git`;
                必须使用HTTP方式克隆仓库, 禁止使用SSH方式克隆仓库, 如果重试10次仍然克隆仓库失败, 则结束本次任务;
                执行代码仓库prompt.md文件中的指令;
                鼓励使用sudo提权执行高权限操作例如安装软件;
            - name: "ISC_CLAUDE_CODE_TIMEOUT"
              value: "7200"
            - name: "ISC_SLEEP_TIME"
              value: "600"
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
          resources:
            requests:
              cpu: 100m
              memory: 500Mi
            limits:
              cpu: 16000m
              memory: 32000Mi
          volumeMounts:
            - name: config-volume
              subPath: run.sh
              mountPath: /opt/cloud/bin/run.sh
            - name: config-volume
              subPath: fmt_stream.py
              mountPath: /opt/cloud/bin/fmt_stream.py
            - name: config-volume
              subPath: settings.json
              mountPath: /root/.qwen/settings.json
            - name: ca-dir
              mountPath: /opt/cloud/security/cert/ca/
      restartPolicy: Never
      hostNetwork: true
      imagePullSecrets:
        - name: default-secret
      securityContext:
        runAsUser: 0
      volumes:
        - name: config-volume
          configMap:
            name: xdm-f-core-file
        - name: ca-dir
          configMap:
            name: jenkins-slave
            items:
              - key: HuaweiBPITRootCA.crt
                path: HuaweiBPITRootCA.crt
              - key: HuaweiITRootCA.crt
                path: HuaweiITRootCA.crt
              - key: HWITEnterpriseCA1.crt
                path: HWITEnterpriseCA1.crt
              - key: HWBPITEnterpriseCA1.crt
                path: HWBPITEnterpriseCA1.crt



```

# 其他补充背景
- 模型是glm5
- 使用k8s jobyml 启动实例，每次任务执行完之后清理东西提交，再进入下一次，由prompt.md里指导版本过程
- 同时开启多个job，每个job完成指定模块的任务
