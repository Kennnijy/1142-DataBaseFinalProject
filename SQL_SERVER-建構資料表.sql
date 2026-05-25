USE [1142DataBase_FinalProject];
GO

-- ==============================================================================
-- 1. 刪除舊表、舊 View 與舊 Trigger (確保資料庫乾淨重來)
-- ==============================================================================
IF OBJECT_ID('dbo.Tri_UpdateBikeStatusAfterRental', 'TR') IS NOT NULL DROP TRIGGER dbo.Tri_UpdateBikeStatusAfterRental;
IF OBJECT_ID('dbo.Tri_LogRentalOrderHistory', 'TR') IS NOT NULL DROP TRIGGER dbo.Tri_LogRentalOrderHistory; -- 💡 刪除舊的歷史紀錄 Trigger
IF OBJECT_ID('dbo.租借單修改歷史表', 'U') IS NOT NULL DROP TABLE dbo.租借單修改歷史表; -- 💡 刪除舊的歷史紀錄表
IF OBJECT_ID('dbo.租借單主表', 'U') IS NOT NULL DROP TABLE dbo.租借單主表;
IF OBJECT_ID('dbo.重型機車資料表', 'U') IS NOT NULL DROP TABLE dbo.重型機車資料表;
IF OBJECT_ID('dbo.車友資料表', 'U') IS NOT NULL DROP TABLE dbo.車友資料表;
IF OBJECT_ID('dbo.View_車款庫存與租借狀況', 'V') IS NOT NULL DROP VIEW dbo.View_車款庫存與租借狀況;
IF OBJECT_ID('Pro_GenerateMegaBikesv3') IS NOT NULL DROP PROCEDURE Pro_GenerateMegaBikesv3;
GO

-- ==============================================================================
-- 2. 建立資料表 (建表)
-- ==============================================================================
CREATE TABLE 車友資料表 (
    車友編號 INT IDENTITY(1,1) PRIMARY KEY,
    車友姓名 NVARCHAR(50) NOT NULL,
    身分證字號 VARCHAR(10) NOT NULL UNIQUE,
    聯絡電話 VARCHAR(20) NOT NULL,
    駕照等級 NVARCHAR(20) NOT NULL
);

CREATE TABLE 重型機車資料表 (
    車輛編號 INT IDENTITY(1,1) PRIMARY KEY,
    車牌號碼 VARCHAR(20) NOT NULL UNIQUE,
    車輛款式 NVARCHAR(50) NOT NULL,
    車輛分類 NVARCHAR(20) NOT NULL, 
    廠牌 NVARCHAR(30) NOT NULL,
    排氣量CC INT NOT NULL,
    每日租金 INT NOT NULL,
    車輛狀態 NVARCHAR(20) DEFAULT N'可用'
);

CREATE TABLE 租借單主表 (
    租單編號 INT IDENTITY(1,1) PRIMARY KEY,
    車友編號 INT FOREIGN KEY REFERENCES 車友資料表(車友編號),
    車輛編號 INT FOREIGN KEY REFERENCES 重型機車資料表(車輛編號),
    租借日期 DATE NOT NULL,
    預計租借天數 INT NOT NULL,
    預計還車日期 DATE NOT NULL, 
    歸還日期 DATE NULL, 
    總計金額 INT DEFAULT 0,
    結帳方式 NVARCHAR(20) DEFAULT N'未結帳',
    是否結清 NVARCHAR(20) DEFAULT N'未結清',
    
    出車經辦 NVARCHAR(150) NULL,
    還車經辦 NVARCHAR(150) NULL,
    最後修改經辦 NVARCHAR(150) NULL
);
GO

-- 💡 需求擴充：建立租借單修改歷史表 (記錄每一次的更動軌跡)
CREATE TABLE 租借單修改歷史表 (
    歷史紀錄編號 INT IDENTITY(1,1) PRIMARY KEY,
    租單編號 INT NOT NULL, -- 不加外鍵以免主表刪除單據時卡住，或可設定 ON DELETE CASCADE
    車友編號 INT,
    車輛編號 INT,
    租借日期 DATE,
    預計租借天數 INT,
    預計還車日期 DATE,
    歸還日期 DATE,
    總計金額 INT,
    結帳方式 NVARCHAR(20),
    是否結清 NVARCHAR(20),
    修改前出車經辦 NVARCHAR(150),
    修改前還車經辦 NVARCHAR(150),
    最後修改經辦 NVARCHAR(150),       -- 紀錄是誰執行這次修改的
    修改時間 DATETIME DEFAULT GETDATE() -- 自動記錄修改當下的時間戳
);
GO

-- ==============================================================================
-- 3. 建立車款庫存動態統計 View 
-- ==============================================================================
CREATE VIEW View_車款庫存與租借狀況 AS
SELECT 
    車輛款式, 
    MIN(車輛分類) AS 車輛分類, 
    MIN(廠牌) AS 廠牌, 
    MIN(排氣量CC) AS 排氣量CC, 
    MIN(每日租金) AS 每日租金,
    COUNT(*) AS 總台數,
    SUM(CASE WHEN 車輛狀態 = N'可用' THEN 1 ELSE 0 END) AS 剩餘可用台數
FROM 重型機車資料表
GROUP BY 車輛款式;
GO

-- ==============================================================================
-- 4. 建立庫存連動 Trigger (維持原功能，處理狀態連動)
-- ==============================================================================
CREATE TRIGGER Tri_UpdateBikeStatusAfterRental
ON 租借單主表
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    
    UPDATE 重型機車資料表
    SET 車輛狀態 = N'租借中'
    FROM 重型機車資料表 m
    JOIN inserted i ON m.車輛編號 = i.車輛編號
    WHERE i.歸還日期 IS NULL;

    UPDATE 重型機車資料表
    SET 車輛狀態 = N'可用'
    FROM 重型機車資料表 m
    JOIN inserted i ON m.車輛編號 = i.車輛編號
    WHERE i.歸還日期 IS NOT NULL;
END;
GO

-- ==============================================================================
-- 4.5 💡 新增：建立歷史紀錄 Trigger (當更新發生時，自動把舊資料寫入歷史表)
-- ==============================================================================
CREATE TRIGGER Tri_LogRentalOrderHistory
ON 租借單主表
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    -- 只有當真正的欄位有變更時才寫入歷史（避免重複執行無意義的 Log）
    -- 這裡將更新前（deleted 表）的快照存入歷史表，並抓取是誰（inserted 表的最後修改經辦）改的
    INSERT INTO 租借單修改歷史表 (
        租單編號, 車友編號, 車輛編號, 租借日期, 預計租借天數, 預計還車日期, 
        歸還日期, 總計金額, 結帳方式, 是否結清, 修改前出車經辦, 修改前還車經辦, 
        最後修改經辦, 修改時間
    )
    SELECT 
        d.租單編號, 
        d.車友編號, 
        d.車輛編號, 
        d.租借日期, 
        d.預計租借天數, 
        d.預計還車日期, 
        d.歸還日期, 
        d.總計金額, 
        d.結帳方式, 
        d.是否結清, 
        d.出車經辦, 
        d.還車經辦,
        i.最後修改經辦, -- 從新資料中抓取本次修改的操作人員
        GETDATE()
    FROM deleted d
    JOIN inserted i ON d.租單編號 = i.租單編號;
END;
GO

-- ==============================================================================
-- 5. 預存程序：密集寫入 10 大品牌、50 款以上台灣熱門車型
-- ==============================================================================
CREATE PROCEDURE Pro_GenerateMegaBikesv3
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @i INT;
    
    -- 【1. SYM 三陽機車系列】
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('SYM-T1-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'SYM T1 150 (經典輕檔)', N'普通重機', N'SYM', 149, 450, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('SYM-T2A-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'SYM T2 249 (白牌版)', N'普通重機', N'SYM', 249, 550, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('SYM-T2B-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'SYM T2 251 (黃牌版)', N'大型重機', N'SYM', 251, 1000, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('SYM-T3-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'SYM T3 278 (黃牌鋼炮)', N'大型重機', N'SYM', 278, 1100, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('SYM-JMZ-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'SYM Joymax Z+ 300 (路權大羊)', N'大型重機', N'SYM', 278, 1200, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('SYM-350R-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'SYM Cruisym 350RS (旗艦跑旅)', N'大型重機', N'SYM', 330, 1400, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('SYM-SB30-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'SYM 大野狼 SB300', N'大型重機', N'SYM', 278, 1200, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('SYM-WOLF-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'SYM 野狼傳奇 125', N'普通重機', N'SYM', 124, 400, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('SYM-JETS-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'SYM JET SL+ 158', N'普通重機', N'SYM', 158, 600, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('SYM-MMB-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'SYM MMBCU 158曼巴', N'普通重機', N'SYM', 158, 650, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('SYM-TL50-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'SYM MAXSYM TL 508', N'大型重機', N'SYM', 508, 1800, N'可用'); SET @i = @i + 1; END

    -- 【2. TRIUMPH 凱旋系列】
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('TRI-TR40-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'TRIUMPH Speed 400 (黃牌型格)', N'大型重機', N'TRIUMPH', 398, 1300, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('TRI-SC40-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'TRIUMPH Scrambler 400X', N'大型重機', N'TRIUMPH', 398, 1400, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('TRI-T100-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'TRIUMPH Bonneville T100', N'大型重機', N'TRIUMPH', 900, 3200, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('TRI-TR66-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'TRIUMPH Trident 660 (三缸)', N'大型重機', N'TRIUMPH', 660, 2200, N'可用'); SET @i = @i + 1; END

    -- 【3. DUCATI 杜卡迪系列】
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('DUC-MON9-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'DUCATI Monster 937 (經典怪獸)', N'大型重機', N'DUCATI', 937, 3800, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('DUC-V4S-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'DUCATI Panigale V4 S', N'大型重機', N'DUCATI', 1103, 7500, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('DUC-SFV4-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'DUCATI Streetfighter V4', N'大型重機', N'DUCATI', 1103, 6800, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('DUC-SCR8-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'DUCATI Scrambler Icon 800', N'大型重機', N'DUCATI', 803, 2800, N'可用'); SET @i = @i + 1; END

    -- 【4. APRILIA 阿普利亞系列】
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('APR-RS66-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'APRILIA RS 660 (中量級仿賽)', N'大型重機', N'APRILIA', 659, 2500, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('APR-RS45-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'APRILIA RS 457 (新世代黃牌)', N'大型重機', N'APRILIA', 457, 1600, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('APR-RS12-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'APRILIA RS4 125 (歐系白牌跑車)', N'普通重機', N'APRILIA', 124, 800, N'可用'); SET @i = @i + 1; END

    -- 【5. YAMAHA 台灣山葉系列】
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('YAM-R1M-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'YAMAHA YZF-R1M', N'大型重機', N'YAMAHA', 1000, 5500, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('YAM-R7-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'YAMAHA YZF-R7', N'大型重機', N'YAMAHA', 689, 2000, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('YAM-R3-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'YAMAHA YZF-R3', N'大型重機', N'YAMAHA', 321, 1200, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('YAM-R15M-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'YAMAHA YZF-R15M V4', N'普通重機', N'YAMAHA', 155, 650, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('YAM-MT09-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'YAMAHA MT-09 SP', N'大型重機', N'YAMAHA', 890, 2500, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('YAM-MT07-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'YAMAHA MT-07', N'大型重機', N'YAMAHA', 689, 1800, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('YAM-MT15-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'YAMAHA MT-15', N'普通重機', N'YAMAHA', 155, 600, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('YAM-XMAX-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'YAMAHA XMAX 300', N'大型重機', N'YAMAHA', 292, 1300, N'可用'); SET @i = @i + 1; END
    
    -- 【6. HONDA 本田系列】
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('HON-R1K-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'HONDA CBR1000RR-R SP', N'大型重機', N'HONDA', 1000, 5800, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('HON-C65R-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'HONDA CBR650R', N'大型重機', N'HONDA', 649, 1900, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('HON-C50R-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'HONDA CBR500R', N'大型重機', N'HONDA', 471, 1400, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('HON-C15R-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'HONDA CBR150R', N'普通重機', N'HONDA', 149, 650, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('HON-CB650-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'HONDA CB650R', N'大型重機', N'HONDA', 649, 1800, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('HON-CB300-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'HONDA CB300R', N'大型重機', N'HONDA', 286, 1000, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('HON-CB150-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'HONDA CB150R', N'普通重機', N'HONDA', 149, 600, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('HON-REB5-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'HONDA Rebel 500', N'大型重機', N'HONDA', 471, 1600, N'可用'); SET @i = @i + 1; END

    -- 【7. KAWASAKI 川崎系列】
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('KAW-ZX1K-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'KAWASAKI Ninja ZX-10R', N'大型重機', N'KAWASAKI', 998, 4800, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('KAW-ZX6R-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'KAWASAKI Ninja ZX-6R', N'大型重機', N'KAWASAKI', 636, 3000, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('KAW-N400-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'KAWASAKI Ninja 400', N'大型重機', N'KAWASAKI', 399, 1300, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('KAW-Z900-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'KAWASAKI Z900RS', N'大型重機', N'KAWASAKI', 948, 2600, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('KAW-Z400-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'KAWASAKI Z400', N'大型重機', N'KAWASAKI', 399, 1200, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('KAW-H2-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'KAWASAKI Ninja H2 (賽道神獸)', N'大型重機', N'KAWASAKI', 998, 8500, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('KAW-H2R-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'KAWASAKI Ninja H2R (終極極限增壓)', N'大型重機', N'KAWASAKI', 998, 15000, N'可用'); SET @i = @i + 1; END

    -- 【8. SUZUKI 鈴木系列】
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('SUZ-GSXR-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'SUZUKI GSX-R1000R', N'大型重機', N'SUZUKI', 999, 4500, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('SUZ-R150-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'SUZUKI GSX-R150 小阿魯', N'普通重機', N'SUZUKI', 147, 600, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('SUZ-S150-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'SUZUKI GSX-S150 小街魯', N'普通重機', N'SUZUKI', 147, 550, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('SUZ-SV65-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'SUZUKI SV650', N'大型重機', N'SUZUKI', 645, 1500, N'可用'); SET @i = @i + 1; END

    -- 【9. BMW 寶馬系列】
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('BMW-S1K-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'BMW S1000RR (當家超跑)', N'大型重機', N'BMW', 999, 5200, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('BMW-G310-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'BMW G310R (德系輕量街車)', N'大型重機', N'BMW', 313, 1200, N'可用'); SET @i = @i + 1; END

    -- 【10. KYMCO 光陽系列】
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('KYM-KTR-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'KYMCO KTR 150', N'普通重機', N'KYMCO', 149, 450, N'可用'); SET @i = @i + 1; END
    SET @i = 1; WHILE @i <= 30 BEGIN INSERT INTO 重型機車資料表 VALUES ('KYM-AK57-'+RIGHT('00'+CAST(@i AS VARCHAR),2), N'KYMCO AK550 Premium', N'大型重機', N'KYMCO', 550, 2200, N'可用'); SET @i = @i + 1; END
END;
GO

EXEC Pro_GenerateMegaBikesv3;
GO