USE [1142DataBase_FinalProject]; -- 💡 強制將這個分頁的底層 Session 轉過來
GO

SELECT * FROM 租借單修改歷史表; -- 這樣不管下拉選單怎麼跳，都絕對100%安全
SELECT * FROM 車友資料表;
SELECT * FROM 重型機車資料表;
SELECT * FROM 租借單主表;
SELECT * FROM 租借單修改歷史表;
SELECT * FROM View_車款庫存與租借狀況;