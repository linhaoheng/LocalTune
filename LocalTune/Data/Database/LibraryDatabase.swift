import Foundation
import GRDB

/// 「把曲库准备好」这件事失败的原因 —— 打开文件、跑去表结构，两步都可能失败。
///
/// 存在的意义是**别把底层那个原始错误裸着抛给界面**：SQLite 扔出来的是
/// `unable to open database file` 这类英文底层说法，界面既显示不了、也不知道该怎么提示用户。
/// 包一层之后，界面拿到的是「为什么失败 + 该怎么办」两句话，**都是中文、都看得懂**。
enum LibraryDatabaseError: LocalizedError {

    /// 文件打不开。
    ///
    /// `error` 保留原始错误 —— **它只给开发看**（排查时打个断点就拿到了），界面不显示它，
    /// 理由见 `failureReason`。
    case cannotOpen(path: String, error: Error)

    /// 文件打开了，但表结构那一步没跑过去。
    case cannotMigrate(path: String, error: Error)

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let path, _):
            return "打不开曲库数据库：\(path)"
        case .cannotMigrate(let path, _):
            return "曲库数据库升级失败：\(path)"
        }
    }

    /// 「为什么失败」—— **故意不用底层的 `localizedDescription`**。
    ///
    /// 🔴 那一句是 SQLite 的英文原文，而这一行是**给用户看的**：用户看不懂英文报错，
    /// 也做不了什么。真正需要对上号的是下面那句"怎么办"。
    /// 原始错误在各自的 `error` 里留着，开发排查时断点就能看到（见那两个 case 的说明）。
    var failureReason: String? {
        switch self {
        case .cannotOpen:
            return "这个文件读不了 —— 可能损坏了、被别的程序占着，或者磁盘空间不够。"
        case .cannotMigrate:
            return "这个版本的表结构和手机里已有的那份对不上。"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .cannotOpen:
            return "文件可能损坏、被占用，或者磁盘空间不够。音乐文件都在音乐文件夹里，重建一个空库不会丢音乐本身 —— 但收藏和歌单会丢。"
        case .cannotMigrate:
            return "通常是这个版本的数据库结构和手机里已有的那份对不上。删掉库文件重建就能恢复，音乐文件不受影响 —— 但收藏和歌单会丢。"
        }
    }
}

/// 曲库数据库 —— **全工程唯一碰 SQL 的地方**：建库、建表、迁移都收在这儿。
///
/// 上层（`LibraryStore`、各页面）只从这里拿连接，不自己拼 SQL、不自己开库。
enum LibraryDatabase {

    /// 曲库数据库文件的默认位置：`Application Support/LocalTune.sqlite`。
    ///
    /// **不放 `Documents/`** —— 那个目录会被「文件」App 整个亮给用户（文件共享开着），
    /// 库文件是应用自己的数据，不该跟用户的歌摆在一起 —— 放 `Application Support`。
    /// 另外 `Application Support` 默认参与 iCloud 备份 —— 收藏和歌单正该备份的是它。
    static var defaultPath: String {
        URL.applicationSupportDirectory
            .appending(path: "LocalTune.sqlite")
            .path(percentEncoded: false)
    }

    /// 打开（没有就建）曲库数据库，跑完迁移再返回连接。
    ///
    /// ⚠️ **刻意只做"打开"，不做"打不开就重建"**：自动清库重建属于会丢用户数据的动作，
    /// 不能藏在打开这一步里偷偷做。失败就抛 `LibraryDatabaseError`，由上层决定是提示用户、
    /// 还是引导重建。
    static func open(at path: String = defaultPath) throws -> any DatabaseWriter {
        var configuration = Configuration()
        // 默认就是开的，写出来是为了让人看见「这条是有意要的」。
        configuration.foreignKeysEnabled = true

        // ⚠️ **这里刻意不写 `busyMode`**：它是「多个连接」才有的概念，而下面用的是
        // `DatabaseQueue` —— 只有**一个**连接、内部把所有访问排成一队，两个线程同时读写
        // 不会撞锁、只会排队，所以那一行永远触发不了。
        // （哪天换成 `DatabasePool`（多连接），才需要它，到时候写的理由才对。）

        // `Application Support` 目录系统**不保证已存在**（首次启动多半没有），
        // 不建的话下面建库直接失败。`createDirectory` 对已存在的目录是无害的。
        let directory = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true
            )
        } catch {
            throw LibraryDatabaseError.cannotOpen(path: path, error: error)
        }

        let writer: DatabaseQueue
        do {
            writer = try DatabaseQueue(path: path, configuration: configuration)
        } catch {
            throw LibraryDatabaseError.cannotOpen(path: path, error: error)
        }

        do {
            try migrator.migrate(writer)
        } catch {
            throw LibraryDatabaseError.cannotMigrate(path: path, error: error)
        }

        return writer
    }

    // MARK: - 表结构
    //
    // 🔴 **这个新项目只有一条迁移** —— 它不是"第几次改表"，它就是**整套表结构本身**。
    //
    // 「迁移」这个机制不是"给老版本升级用的功能"，它是 GRDB **建表 / 改表的入口**：
    // 库里有一张记账表记着跑到第几条了，跑过的不会重跑。所以新项目的形状就该是**一条**；
    // 等第一版发出去之后，再动表结构才叫"追加新的一条"。

    /// 表结构**定下来就不变**，所以用 `let`（配一次性的闭包）。
    ///
    /// ## 什么时候改这一条、什么时候追加新的
    ///
    /// - **第一版发出去之前 —— 改表结构就直接改这一条**（下面的 `eraseDatabaseOnSchemaChange`
    ///   会把开发机上的旧库整库擦掉重建，不会挡路）。
    ///   ⚠️ **不要**为了"加一列"再往上堆一条新迁移 —— 这个项目里**没有老库要改**，
    ///   堆出来的那几条只是把同一份表结构拆散在好几个地方，读的人得拼起来才看得懂。
    /// - **第一版发出去之后 —— 这一条就冻住了**：名字跑过一次就被记下，
    ///   以后动表结构只能**追加新的一条**（`v2_xxx`）。改了这条的 SQL 而名字不变，
    ///   库会认为它跑过了、不重跑，于是你写的表结构和库里的**悄悄对不上**，而且不报错
    ///   （发布版没有 `eraseDatabaseOnSchemaChange` 那层保护）。
    ///
    /// 写成计算属性的话，每访问一次就重新构造一遍整个列表 —— 结果一样，但白做工。
    private static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()

        #if DEBUG
        // 开发期：表结构和这里写的对不上就把整库擦掉重建，省得手工删库。
        //
        // ⚠️ 触发条件是「**`sqlite_master` 里有任何一处 SQL 不一样**」，也包括"某条迁移被删掉 / 改名"。
        // 它**不会掩盖迁移里的错误**（迁移抛错照样抛），真正的代价是：
        // 改了建表语句就会**静默把数据清掉重建** —— 收藏和歌单就没了。
        // 开发期无所谓（曲子重新扫一遍），发布版绝不开（这里已经用 DEBUG 包住）。
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1_initial_schema") { db in
            // ⚠️ 一条排序规矩：**「按导入时间排序」必须带「入库先后」兜底**。
            //
            // 两个原因叠在一起：`date_added` 只有毫秒精度（**同一毫秒里落库的两首**就并列），
            // 而 Swift 的排序**不保证稳定**（标准库原话：不保证并列元素的相对顺序）——
            // 只按时间排，并列那几首的先后就是不确定的，用户看到「每次打开顺序都不一样」。
            //
            // 「入库先后」在两个层次各有落地形态：
            //   在 SQL 里排 → `ORDER BY date_added, rowid`（`rowid` 是隐藏列，零成本，语义正好是入库先后）；
            //   在页面那层排（`LibraryStore` 不排序，排法是页面的决定）→
            //     用 store 给出的**原始数组顺序**兜底，不需要把 `rowid` 传到 Swift 侧。
            //
            // 🔴 **常见的那种写法不能照抄**：比较器的结尾拿 `!ascending` 把方向取反 ——
            // 降序时并列会返回 `true`（连「自己排在自己前面」都成立）。
            // Swift 的排序要求比较函数是**严格弱序**（自己跟自己比必须为 false），
            // 违反之后**结果不保证正确**。
            // 而且并列不是罕见情况：空标题的歌、同一毫秒落库的两首，都是整片并列。
            //
            // 为什么这两列的时间**故意**用两种格式（这列毫秒字符串、`file_modification_date` 微秒整数）：
            //   `file_modification_date` 要**跟硬盘给的原值一模一样**（差一点，"文件变过没"就永远误判），
            //   所以必须原样存整数；
            //   而这一列**不跟任何外部值比对**，只比大小 —— 丢精度只会让两首歌并列，不会算错。
            // 也不能靠"提高精度"来省掉兜底判据：精度降的是**撞车概率**，降不到零
            // （连着导入时，总有那么两首会落在同一毫秒）。让顺序固定的是上面那个 `rowid`。
            // `rowid` 是 SQLite 的隐藏列：不占空间、不用另建索引，语义正好是「入库先后」。
            // 重新导入同一首歌走的是「改那一行」而不是「删了重插」，所以它的 `rowid` 不会被换掉。
            //
            // 建表用原始 SQL 而不是 `db.create(table:)` 那段 DSL：
            // 只有写 SQL 才用得上 `STRICT`（GRDB 的 DSL 没有这个选项），
            // 而 STRICT 能把「往文字栏里塞数字」这类错误挡在写入那一刻。
            //
            // 末尾三列（`*_pinyin`）**不是给人看的**：它们是搜索索引键（全拼 + 连写全拼 + 首字母），
            // 由 `LibraryStore` 在写库那一刻按标签现算现填（见 `withSearchKeysFilled`）——
            // 拼音必须**预先算好存下来**，不然用户每敲一个字都要现算几万条。
            //
            // `custom_lyrics` 留在本表：它是「编辑歌词」页写的自定义层，**空串占 1 字节**
            //（`NOT NULL DEFAULT ''`，绝大多数歌从没编辑过）⇒ **不是**扫描变慢的贡献者。
            // 🔴 内嵌 `lyrics` 已经**拆到侧表** `track_lyrics`（见下面那张表的说明）——
            // 它一首 1~5 KB，留在行里会让**每次全表扫描多读近一倍字节**（SQLite 是行存：
            // 即使 `SELECT "id"` 也要读整行）。口径与判据见 `歌词拆侧表设计.md`。
            //
            // `custom_lyrics` 和 `lyrics` 分开的原因不变：编辑歌词页不写回音频；
            // `lyrics` 重扫会被内嵌覆盖，而用户编辑的结果必须活下来。
            //
            // `missing_since`：**文件从什么时候起不在本机了**。`NULL` ＝ 在。
            //
            // 🔴 它不是「文件被删了」的记号，而是「这一行指的那个文件，现在找不到」——
            // 行照旧留着（播放次数 / 收藏 / 歌单归属都挂在它上面），文件回来**自己就清掉**
            // （身份是路径 ⇒ 路径没变就是同一首）。什么时候标、什么时候清见 `LibraryReconcile`。
            //
            // 可空、**不给默认值** —— 跟 `favorites.added_at` 一个口径：真没有真实时间的行
            // 就该是 `NULL`，编一个当前时间填进去就是假数据。
            try db.execute(sql: """
                CREATE TABLE "tracks" (
                  "id" TEXT PRIMARY KEY NOT NULL,
                  "path" TEXT NOT NULL DEFAULT '',
                  "file_name" TEXT NOT NULL DEFAULT '',
                  "fingerprint" TEXT NOT NULL DEFAULT '',
                  "title" TEXT NOT NULL DEFAULT '',
                  "artist" TEXT NOT NULL DEFAULT '',
                  "album" TEXT NOT NULL DEFAULT '',
                  "album_artist" TEXT,
                  "genre" TEXT,
                  "composer" TEXT,
                  "comment" TEXT,
                  "release_date" TEXT,
                  "track_number" INTEGER,
                  "total_tracks" INTEGER,
                  "disc_number" INTEGER,
                  "total_discs" INTEGER,
                  "duration_ms" INTEGER,
                  "bit_rate" INTEGER,
                  "sample_rate" INTEGER,
                  "bit_depth" INTEGER,
                  "channels" INTEGER,
                  "format" TEXT,
                  "artwork_path" TEXT,
                  "file_size" INTEGER,
                  "file_modification_date" INTEGER,
                  "missing_since" TEXT,
                  "date_added" TEXT NOT NULL,
                  "play_count" INTEGER NOT NULL DEFAULT 0,
                  "custom_lyrics" TEXT NOT NULL DEFAULT '',
                  "title_pinyin" TEXT,
                  "artist_pinyin" TEXT,
                  "album_pinyin" TEXT
                ) STRICT
                """)

            // 歌词侧表 —— **垂直分区**：把「扫描用不上的大列」从 `tracks` 挪出来。
            //
            // 🔴 **为什么**：SQLite 是**行存**库 —— `SELECT "id" FROM "tracks" WHERE …` 这条搜索扫描
            // 即使只要 id，也会把整行读出来；`lyrics` 一首 1~5 KB，直接让每次搜索**多读近一倍字节**
            //（实测 5 万首 63.8 → 39.7 ms）。而我们**从不搜歌词**（FTS5 装的是拼音三列，
            // 见下面那段注释）。两张表各占各的页 ⇒ 扫 `tracks` 只读窄行。论证见 `歌词拆侧表设计.md`。
            //
            // 🔴 **没有行 ＝ 这首歌没有内嵌歌词** —— 不对没歌词的歌插空行（白写）。
            // 行既然在，`lyrics` 就**不能**是 NULL（`NOT NULL`）——那会把"没有行"和"有一行空的"
            // 变成两句话说同一件事。
            //
            // 主键列就叫 `id`、**不是** `track_id` —— 这是 1:1 附属实体，**跟 `favorites` 完全同形状**
            //（那张也这么叫）。而且 GRDB 认主键**只看 `id` 这个名字**：叫别的它会退到 `rowID`，
            // `fetchOne(db, key:)` 就查错列（静默）。
            // `ON DELETE CASCADE`：删歌时这行跟着走，不靠谁记得清（同 `favorites` / `playlist_tracks`）。
            try db.execute(sql: """
                CREATE TABLE "track_lyrics" (
                  "id" TEXT PRIMARY KEY NOT NULL REFERENCES "tracks"("id") ON DELETE CASCADE,
                  "lyrics" TEXT NOT NULL
                ) STRICT
                """)

            // 歌单。
            //
            // 🔴 **「最爱的歌曲」不是一张单独的表，就是这里的一行** —— `kind = 'favorites'`、
            // id 固定（见 `Playlist.favoritesID`）。这样「有哪些歌单」始终只有一处答案。
            // ⚠️ 但它的**成员不在 `playlist_tracks` 里**：那是收藏表（`favorites`）的事。
            // 同一个事实存两份，迟早对不上 —— 分派只有 `LibraryStore.tracks(in:)` 一处知道。
            //
            // `artwork_path` 只存**用户手挑的那张封面**（图在 `Library/covers/`）——
            // 从歌曲封面拼出来的那张是**缓存**（能重算），不进库。
            //
            // 时间列跟别处一个口径：**不给默认值**（`created_at` 是建单那一刻填的真时间；
            // 编一个当前时间当默认值就是假数据）。
            try db.execute(sql: """
                CREATE TABLE "playlists" (
                  "id" TEXT PRIMARY KEY NOT NULL,
                  "name" TEXT NOT NULL DEFAULT '',
                  "kind" TEXT NOT NULL DEFAULT 'user',
                  "artwork_path" TEXT,
                  "created_at" TEXT NOT NULL,
                  "sort_index" INTEGER NOT NULL DEFAULT 0
                ) STRICT
                """)

            // 关联表：主键就是「哪个歌单 + 哪首歌」这一对，**没有单独的编号** ——
            // 这样同一首歌在同一个歌单里天然只可能出现一次，不用再加一条「不许重复」的索引去堵。
            // ⚠️ 两列都写 NOT NULL：SQLite 的表主键列默认**允许 NULL**，不写就堵不住。
            // 删歌单或删歌时，这条关联跟着走（ON DELETE CASCADE），不会留下指向空处的行。
            try db.execute(sql: """
                CREATE TABLE "playlist_tracks" (
                  "playlist_id" TEXT NOT NULL REFERENCES "playlists"("id") ON DELETE CASCADE,
                  "track_id" TEXT NOT NULL REFERENCES "tracks"("id") ON DELETE CASCADE,
                  "position" INTEGER NOT NULL DEFAULT 0,
                  PRIMARY KEY ("playlist_id", "track_id")
                ) STRICT
                """)

            // 收藏：一条记录除了「是哪首歌」只有「什么时候收的」，所以主键直接复用 `tracks.id`，
            // 顺带把「收藏的必须是库里有的歌」交给外键去保证。
            //
            // `added_at`：类型是 `TEXT`（GRDB 把 `Date` 编成能读的字符串），跟 `tracks.date_added` /
            // `playlists.created_at` 一个口径 —— 「时间」在一个库里只有一种存法。
            // **可空、不给默认值**：真没有真实时间的行就该是 `NULL`（＝「不知道」），
            // 编一个当前时间填进去就是假数据，以后按收藏时间排序时它会混在真的时间里面。
            try db.execute(sql: """
                CREATE TABLE "favorites" (
                  "id" TEXT PRIMARY KEY NOT NULL REFERENCES "tracks"("id") ON DELETE CASCADE,
                  "added_at" TEXT
                ) STRICT
                """)

            // 歌单里取歌**总是**「先按歌单筛、再按 position 排」，
            // 所以索引直接建成 (playlist_id, position) —— 排序也一起省掉。
            try db.execute(sql: """
                CREATE INDEX "idx_playlist_tracks_order" ON "playlist_tracks"("playlist_id", "position")
                """)

            // 反过来查「这首歌在哪些歌单里」（删歌时要清关联、详情页要显示归属）。
            try db.execute(sql: """
                CREATE INDEX "idx_playlist_tracks_track" ON "playlist_tracks"("track_id")
                """)

            // 按内容跳过：查的是指纹，不是主键。
            try db.execute(sql: """
                CREATE INDEX "idx_tracks_fingerprint" ON "tracks"("fingerprint")
                """)

            // 全文索引：装的是**光靠子串比不出来的那几样** —— 拼音、拼音首字母。
            // 不装歌词：不搜歌词；列表也显示不了歌词命中。
            //
            // ⚠️ **歌名 / 艺人 / 专辑三列故意不在这儿**：那三个字段的命中由 `instr` 子串匹配负责
            // （`LibraryStore.matchingTrackIDs`）。放进索引等于同一件事做两遍，
            // 而且 FTS5 默认分词器 `unicode61` 把**一串汉字当成一个整词** ——
            // 搜「周杰」搜不到「周杰伦」，反而不如子串匹配。
            // 拼音那几列是按音节用空格分开的（`zhou jie lun zhoujielun zjl`），
            // 切词之后每个音节 / 缩写都是一个 token，所以「zhou」「zjl」都能前缀命中。
            //
            // `synchronize(withTable:)` 让 GRDB 在 `tracks` 上装好触发器：之后**只要曲库有增删改，
            // 索引自己跟着走** —— 不需要谁记得在写完库之后再同步一次
            // （漏一次就是"列表里有、搜索里没有"这种查不出来的错）。
            try db.create(virtualTable: "track_search", using: FTS5()) { t in
                t.synchronize(withTable: "tracks")
                t.column("title_pinyin")
                t.column("artist_pinyin")
                t.column("album_pinyin")
            }
        }

        return migrator
    }()
}
