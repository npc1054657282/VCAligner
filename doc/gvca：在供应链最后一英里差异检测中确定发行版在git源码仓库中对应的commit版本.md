# gvca：在供应链最后一英里差异检测中确定发行版在git源码仓库中对应的commit版本

## Abstract

## Introduction

## Terminology

## Threat Model

### 供应链交付阶段“最后一英里”的恶意代码植入攻击

### 漏洞重放攻击

## Motivation

## Preliminary 

### git仓库对象模型

git仓库是一个内容寻址文件系统，其核心是一个key-value数据库，git仓库不可变的核心历史内容将以“git object”的形式在此数据库中管理。易变的内容（branch、tag、HEAD、remote-tracking等）则以“ref”的形式保存。

有4种git object：blob、tree、commit、tag。所有的git object的key均为在该git object的value前附加一个git object头信息（包含git object类型和git object内容大小）后计算其SHA校验和获得的哈希值。一个git仓库可支持SHA-1或SHA-256校验和计算，但目前主流在线仓库托管平台中只有gitlab实验性支持SHA-256，包括github在内的多数仓库托管平台仅支持SHA-1。

#### blob对象

blob对象保存一个git仓库历史中存在的文件内容。它不包含文件名等文件内容本身以外的信息。git仓库版本历史中多个内容相同的不同路径或名称文件共享同一个blob对象。

#### tree对象

tree对象保存一个git仓库目录下的内容，由多个tree entry组成，每个tree entry引用另一个tree对象/blob对象/其他仓库的commit对象的key及其元信息，以指代一个子目录/文件/submodule。tree entry使用mode码记录它引用的对象的类型，其中blob对象有三种模式，分别指代普通文件（100644）、可执行文件（100755）和符号链接（120000）。

![tree对象](tree对象.png)

#### commit对象

commit对象保存一个git仓库的一个提交的数据快照与元信息。数据快照是一个tree对象的key，通过遍历该顶层tree对象，得以遍历该提交下的所有文件路径与对应文件内容。元信息包括作者、提交者信息、时间戳，以及可能存在的父提交对象的key。

![commit对象](commit对象.png)

## Methodology

在分析和建模git仓库的对象模型时，我们重点关注commit和文件内容之间的关系。一个关键的观察结果是，排除空目录和子模块，Git 存储库的对象组织可以抽象为从提交集合到文件路径-内容对集合的多值映射。形式化表达为令 $\mathcal{F} \subseteq \mathcal{C} \times \mathcal{P} \times \mathcal{B}$ 表示此关系，其中：

- $\mathcal{C}$ 是提交对象集合，
- $\mathcal{P}$ 是文件路径集合,
- $\mathcal{B}$ 是数据块对象集合（代表文件内容）

每个元组 $(c, p, b) \in \mathcal{F}$ 表明提交 $c \in \mathcal{C}$ 包含路径为 $p \in \mathcal{P}$ 的文件，其内容由数据块 $b \in \mathcal{B}$ 表示。该关系捕获了从提交到多个 $(p, b)$ 对的一对多映射，因为单个提交可能通过其关联的树对象引用多个文件。

对git仓库对象模型的实现，存在一个关键观察：不考虑空目录与submodule时，git仓库的对象组织可以视为commit与(文件名路径-文件blob)的一对多映射的集合 \mathcal{F} 。

![git提交与文件内容关系](git提交与文件内容关系.png)

注意到，通过重组 $\mathcal{F}$ 可推导出逆关系 $\mathcal{F}^{-1} \subseteq \mathcal{P} \times \mathcal{B} \times \mathcal{C}$ 。对于给定的文件路径-内容对 $(p, b)$ ，集合 $\{c \in \mathcal{C} \mid (c, p, b) \in \mathcal{F}\}$ 表示路径为 $p$ 且内容为 $b$ 的文件所涉及的所有提交。这种逆向映射同样是一对多关系，因为单个文件路径-内容对可能出现在文件未更改的多个提交中。

![git文件内容与提交关系](git文件内容与提交关系.png)

在release包中，若排除空目录，可将包建模为一组文件路径-内容对 $\{(p, b) \mid p \in \mathcal{P}, b \in \mathcal{B}\}$ ，这些数据源自特定提交的顶层树对象。

通过利用逆向关系 $\mathcal{F}^{-1} \subseteq \mathcal{P} \times \mathcal{B} \times \mathcal{C}$ ，其中 $\mathcal{C}$ 代表提交集合，我们可以将每个文件路径-内容对 $(p, b)$ 映射到一组提交 $\{c \in \mathcal{C} \mid (c, p, b) \in \mathcal{F}\}$ ，这些提交中位于路径 $p$ 的文件具有内容 $b$ 。给定一个发布包的 $(p, b)$ 对集合，我们可以迭代地求取每对关联的提交集合的交集，以缩小候选提交的范围。形式上，对于一个发布包 $R = \{(p_1, b_1), (p_2, b_2), \dots, (p_n, b_n)\}$ ，候选提交集合的计算方式为：
$$C_R = \bigcap_{(p_i, b_i) \in R} \mathcal{F}^{-1}(p_i, b_i).$$

为实现所提出的模型，gvca的实现将包含两个step。Step 1：预处理——建立git仓库逆向关系数据库。Step 2：动态commit筛选——迭代优化给定release包的候选commit集。

### 预处理

为了实现高效查询反向关系，gvca使用RocksDB构建了一个k-v数据库。RocksDB是一种针对快速前缀查找优化的高性能存储引擎。该数据库专门用于存储文件路径-内容对 $(p, b)$ 与其关联提交记录之间的映射关系，从而快速识别给定发布包对应的候选提交。

为优化存储效率，重复出现的长字符串与哈希值被替换为紧凑的序列标识符，以降低了数据库内存占用。为此，数据库采用多列族设计，实现不同的逻辑功能：

- commit序列映射：存储从commit序列号（编码为紧凑的顺序ID）到对应commit hash的映射关系，减少重复出现的commit hash开销。
- path序列映射：存储从path序列号（编码为紧凑的顺序ID）到完整的文件路径字符串，减少重复出现的长路径开销。
- path-blob序列映射：为路径-内容对 $(p, b)$ 分配序列号，并将其与对应的路径序列号和blob hash关联，减少其重复出现开销。
- path排名：基于文件路径在git仓库历史中关联的blob版本的数量记录路径的排名，可用于在分析过程中优先处理频繁修改的路径。
- 逆向关系索引：核心列族。实现为仅含键的空值列，每个键为复合结构，编码了路径-内容对序列号及commit序列号，表示一个元组 $(p, b, c) \in \mathcal{F}^{-1}$ 。通过将所有信息存储于键中并利用RocksDB的prefix extractor优化前缀搜索能力，该设计能快速检索给定 $(p, b)$ 对的所有提交 $\{c \in \mathcal{C} \mid (c, p, b) \in \mathcal{F}\}$ ，同时保持极低的存储和查询开销。

预处理step通过遍历git仓库中所有commit，递归解析tree对象的方式提取文件路径-内容关联关系。为加速此过程，commit对象采用并行解析方式，充分利用多核架构高效处理大规模代码库。提取的元组 $(c, p, b) \in \mathcal{F}$ 随后会被转换为反向关系索引中的键值条目 $(p, b, c)$ 。

为进一步优化写入性能，逆向关系数据库填充过程分为两个阶段：无compaction快速写入阶段和一次性延迟compaction阶段。如此确保初始填充阶段的高写入吞吐量，减小写放大。

Algorithm 1: ConstructInverseMapping
Input: Git repository object database \(\mathcal{D}\), containing sets of commit objects \(\mathcal{C}\), tree objects \(\mathcal{T}\), and blob objects \(\mathcal{B}\)
Output: Inverse relation \(\mathcal{F}^{-1} \subseteq \mathcal{P} \times \mathcal{B} \times \mathcal{C}\)

1: Initialize an empty relation \(\mathcal{F} \gets \emptyset\) {Relation of (commit, path, blob)}
2: for each commit \(c \in \mathcal{C}\) do
3:     \(t \gets \text{GetTopLevelTree}(c)\) {Get top-level tree object}
4:     \(\mathcal{P}_c, \mathcal{B}_c \gets \text{ParseTree}(t)\) {Extract paths and blobs}
5:     for each \((p, b) \in \mathcal{P}_c \times \mathcal{B}_c\) do
6:         Add tuple \((c, p, b)\) to \(\mathcal{F}\)
7:     end for
8: end for
9: Initialize an empty relation \(\mathcal{F}^{-1} \gets \emptyset\)
10: for each tuple \((c, p, b) \in \mathcal{F}\) do
11:     Add tuple \((p, b, c)\) to \(\mathcal{F}^{-1}\)
12: end for
13: Group \(\mathcal{F}^{-1}\) by \((p, b)\) to form sets \(\{(p, b, \{c \mid (p, b, c) \in \mathcal{F}^{-1}\})\}\)
14: return \(\mathcal{F}^{-1}\)


Algorithm 2: RankPathsByUniqueBlobs
Input: Inverse relation \(\mathcal{F}^{-1} \subseteq \mathcal{P} \times \mathcal{B} \times \mathcal{C}\)
Output: Ranked list \(\mathcal{R}\) of paths, sorted by the number of unique blobs in descending order

1: Initialize an empty mapping \(M: \mathcal{P} \to \mathbb{N}\) {Map from path to unique blob count}
2: for each path \(p \in \mathcal{P}\) do
3:     UniqueBlobs \(\gets \{b \mid \exists c: (p, b, c) \in \mathcal{F}^{-1}\}\) {Set of unique blobs for path p}
4:     \(M(p) \gets |\text{UniqueBlobs}|\) {Count of unique blobs}
5: end for
6: Initialize an empty list \(\mathcal{R} \gets \emptyset\)
7: Sort paths in \(\mathcal{P}\) by \(M(p)\) in descending order, and append to \(\mathcal{R}\)
8: return \(\mathcal{R}\)

### 动态commit筛选

动态提交筛选阶段会识别与发布包 $ R $ 对应的候选提交。考虑到发布包与代码仓库提交之间可能存在的差异，如额外文件、内容与代码仓库所有提交不匹配，或来自非连续提交的文件，gvca的方法会维护多个候选集以确保鲁棒性。

#### 发布包预处理

在筛选之前，gvca通过以下方式预处理 $R$ ：

- 识别 $R$ 内在git仓库历史中存在路径的文件。忽略仓库历史中不存在路径的文件。
- 使用git对象的哈希规则计算匹配路径文件内容的blob哈希值 $b_i$ 。
- 对于仓库中不存在内容 $b_i$ 的匹配路径文件，当前阶段视其为非贡献项。这些文件虽不影响提交标识，但会被标记为优先差异分析对象（例如潜在的注入产物）。
- 将得到的匹配对 $\{(p_i, b_i)\}$ 按路径排名排列（依据路径对应的不同blob版本数量降序排名，优先选择高变异性路径以加速收敛）。

这将生成一个有序的贡献者 $(p, b)$ 对列表，随后通过反向关系索引 $\mathcal{F}^{-1}$ 查询对应的提交集合。

#### 核心过滤算法

筛选过程从包含所有提交的初始候选集 $  \mathcal{C}  $ 开始，依次对每个 $  (p_i, b_i) \in R  $ 与 $  \mathcal{F}^{-1}(p_i, b_i)  $ 取交集。为处理文件来源不一致（如来自不相交commit），gvca维护了一个候选集列表 $  \mathcal{S}  $。对于每个 $  (p_i, b_i)  $，gvca选择性地精炼候选集：若某候选集 $ C $ 的交集 $ C' = C \cap \mathcal{F}^{-1}(p_i, b_i) $ 非空，则更新该候选集为 $   C'   $；若交集为空，则保留原候选集不变。若所有候选集的交集均为空，则从 $  \mathcal{F}^{-1}(p_i, b_i)  $ 创建新候选集，并从 $ R $ 开头到当前位置重新筛选以确保一致性。

Algorithm 3: DynamicCommitFiltering
Input: Preprocessed release package \( R = \{(p_1, b_1), \dots, (p_n, b_n)\} \), 
    sorted by path ranking in descending order of blob version count, Inverse relation index \( \mathcal{F}^{-1} \subseteq \mathcal{P} \times \mathcal{B} \times \mathcal{C} \), 
    Set of all commits \( \mathcal{C} \)
Output: List of candidate commit sets \( \mathcal{S} = [C_1, C_2, \dots, C_k] \) for differential analysis

1: Initialize \( \mathcal{S} \gets [\mathcal{C}] \) {Start with a single candidate set containing all commits}
2: for each \( (p, b) \in R \) do {Iterate through release package pairs in path ranking order}
3:     Initialize \( \mathcal{S}' \gets \emptyset \) {Temporary list for updated candidate sets}
4:     has_non_empty_intersection \(\gets\) False {Track if any non-empty intersection exists}
5:     for each \( C \in \mathcal{S} \) do {Process each existing candidate set}
6:         \( C' \gets C \cap \mathcal{F}^{-1}(p, b) \) {Compute intersection with commits for current pair}
7:         if \( C' \neq \emptyset \) then
8:             Append \( C' \) to \( \mathcal{S}' \) {Retain non-empty intersections}
9:             has_non_empty_intersection \(\gets\) True
10:        end if
11:    end for
12:    if not has_non_empty_intersection then {All intersections empty; create new candidate set}
13:        \( NewC \gets \mathcal{F}^{-1}(p, b) \) {Start with commits for current pair}
14:        if \( NewC \neq \emptyset \) then
15:            for each \( (p_j, b_j) \in R \) from index 1 to current index - 1 do {Rescreen from beginning}
16:                \( NewC \gets NewC \cap \mathcal{F}^{-1}(p_j, b_j) \) {Intersect with previous pairs}
17:                if \( NewC = \emptyset \) then
18:                    Break {Stop rescreening if empty}
19:                end if
20:            end for
21:            if \( NewC \neq \emptyset \) then
22:                Append \( NewC \) to \( \mathcal{S}' \) {Add valid new candidate set}
23:            end if
24:        end if
25:    end if
26:    \( \mathcal{S} \gets \mathcal{S}' \) {Update candidate sets, pruning empty ones}
27: end for
28: return \( \mathcal{S} \) {Return final list of candidate sets for differential analysis}

#### 后过滤与应用

完成后，若仅剩单个候选集（或缩减至单次提交），则直接锁定差异分析源头（例如对比发布内容与提交记录的代码树）。多候选集表明存在歧义（如来自不相交commit的文件共存于release包中）。预处理阶段标记的非贡献性文件将在分析中优先处理，用于识别可疑新增或修改内容，从而强化供应链风险检测能力。

## Data Collection

## gvca与代码差异分析及代码扫描工具的联合应用

## Threats to Validity

## Related Work

## Conclusion