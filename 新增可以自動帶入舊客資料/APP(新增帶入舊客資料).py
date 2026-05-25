# -*- coding: utf-8 -*-
from flask import Flask, render_template, request, jsonify
import pyodbc

# 💡 核心設定：讓 Flask 直接在同層根目錄尋找 index.html
app = Flask(__name__, template_folder='.')

# SQL Server 連線設定
def get_db_connection():
    return pyodbc.connect(
        'DRIVER={ODBC Driver 17 for SQL Server};'
        'SERVER=KENNIJY\\KENNIJY;'
        'DATABASE=1142DataBase_FinalProject;'
        'Trusted_Connection=yes;'
    )

@app.route('/')
def index():
    return render_template('租車平台網頁(新增帶入舊客資料).html')

# ==============================================================================
# 新增功能：舊客資料快速搜尋帶入 API (符合 3NF 一體化檢索)
# ==============================================================================
@app.route('/api/search_customer', methods=['POST'])
def search_customer():
    data = request.json
    search_keyword = data.get('keyword', '').strip()
    
    if not search_keyword:
        return jsonify({"status": "empty", "message": "請輸入搜尋關鍵字"})
        
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        
        # 利用 OR 條件，支援以 身分證、姓名、電話、或編號 任意一項精準配對舊客
        query = """
            SELECT 身分證字號, 車友姓名, 聯絡電話, 駕照等級
            FROM 車友資料表 
            WHERE 身分證字號 = ? 
               OR 車友姓名 = ? 
               OR 聯絡電話 = ? 
               OR CAST(車友編號 AS VARCHAR) = ?
        """
        cursor.execute(query, (search_keyword, search_keyword, search_keyword, search_keyword))
        row = cursor.fetchone()
        conn.close()
        
        if row:
            return jsonify({
                "status": "success",
                "data": {
                    "uid": row[0].strip() if row[0] else "",
                    "name": row[1].strip() if row[1] else "",
                    "phone": row[2].strip() if row[2] else "",
                    "license": row[3].strip() if row[3] else ""
                }
            })
        else:
            return jsonify({"status": "not_found", "message": "❌ 查無此舊客紀錄，請手動輸入新客資料！"})
            
    except Exception as e:
        return jsonify({"status": "error", "message": f"資料庫連線或查詢失敗：{str(e)}"}), 500

# ==============================================================================
# 1. 讀取重機車兩庫存與狀態
# ==============================================================================
@app.route('/api/bike_inventory', methods=['GET'])
def get_bike_inventory():
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        cursor.execute("SELECT * FROM View_車款庫存與租借狀況 ORDER BY 車輛款式 ASC")
        data = []
        for row in cursor.fetchall():
            data.append({
                "model": row[0], "type": row[1], "brand": row[2],
                "cc": row[3], "rate": row[4], "total": row[5], "available": row[6]
            })
        conn.close()
        return jsonify(data)
    except Exception as e:
        return jsonify({"status": "error", "message": f"庫存載入失敗：{str(e)}"}), 500

# ==============================================================================
# 2. 臨櫃登記：付款並辦理出車
# ==============================================================================
@app.route('/api/rent_process', methods=['POST'])
def rent_process():
    data = request.json
    name = data.get('name')
    uid = data.get('uid')
    phone = data.get('phone')
    license_type = data.get('license_type')
    model_name = data.get('model_name')
    start_date = data.get('start_date')
    estimated_days = int(data.get('estimated_days'))
    pay_method = data.get('pay_method')
    employee = data.get('employee') 
    
    if not employee or employee.strip() == "":
        return jsonify({"status": "error", "message": "❌ 出車失敗：必須填寫負責出車的經辦人員姓名！"})
        
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        
        cursor.execute("""
            SELECT COUNT(*) FROM 租借單主表 r
            JOIN 車友資料表 c ON r.車友編號 = c.車友編號
            WHERE c.身分證字號 = ? AND r.歸還日期 IS NULL
        """, (uid,))
        if cursor.fetchone()[0] > 0:
            conn.close()
            return jsonify({"status": "error", "message": f"❌ 出車攔截！該車友目前已有租借中車輛，需先辦理還車點收。"})
        
        cursor.execute("SELECT TOP 1 車輛編號, 每日租金 FROM 重型機車資料表 WHERE 車輛款式 = ? AND 車輛狀態 = N'可用'", (model_name,))
        bike_row = cursor.fetchone()
        if not bike_row:
            conn.close()
            return jsonify({"status": "error", "message": f"❌ 出車失敗：該車款目前已無庫存空車！"})
        bike_id, rate = bike_row[0], bike_row[1]
        
        total_cost = estimated_days * rate
        
        cursor.execute("SELECT 車友編號 FROM 車友資料表 WHERE 身分證字號 = ?", (uid,))
        user_row = cursor.fetchone()
        if user_row:
            customer_id = user_row[0]
            cursor.execute("UPDATE 車友資料表 SET 車友姓名=?, 聯絡電話=?, 駕照等級=? WHERE 車友編號=?", (name, phone, license_type, customer_id))
        else:
            cursor.execute("INSERT INTO 車友資料表 (車友姓名, 身分證字號, 聯絡電話, 駕照等級) VALUES (?, ?, ?, ?)", (name, uid, phone, license_type))
            cursor.execute("SELECT @@IDENTITY")
            customer_id = cursor.fetchone()[0]
            
        cursor.execute("""
            INSERT INTO 租借單主表 (車友編號, 車輛編號, 租借日期, 預計租借天數, 預計還車日期, 總計金額, 結帳方式, 是否結清, 出車經辦) 
            VALUES (?, ?, ?, ?, DATEADD(day, ?, ?), ?, ?, N'已付清', CONCAT(?, N' (', FORMAT(GETDATE(), 'yyyy-MM-dd HH:mm:ss'), N')'))
        """, (customer_id, bike_id, start_date, estimated_days, estimated_days, start_date, total_cost, pay_method, employee))
        
        conn.commit()
        conn.close()
        return jsonify({"status": "success", "message": f"付款出車授權成功！(出車經辦已蓋戳記)"})
    except Exception as e:
        return jsonify({"status": "error", "message": f"資料庫寫入錯誤：{str(e)}"}), 500

# ==============================================================================
# 3. 讀取即時租借紀錄明細
# ==============================================================================
@app.route('/api/order_details', methods=['GET'])
def get_order_details():
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        cursor.execute("""
            SELECT 
                r.租單編號, c.車友姓名, c.身分證字號, c.聯絡電話, c.駕照等級,
                m.車輛款式, m.車牌號碼, 
                CONVERT(VARCHAR, r.租借日期, 111) AS 起租日, 
                CONVERT(VARCHAR, r.預計還車日期, 111) AS 預計還車日,
                r.預計租借天數,
                CASE WHEN r.歸還日期 IS NULL THEN '租借中' ELSE CONVERT(VARCHAR, r.歸還日期, 120) END AS 實際歸還狀態,
                r.總計金額, r.結帳方式, r.是否結清, m.每日租金,
                r.出車經辦, r.還車經辦, r.最後修改經辦
            FROM 租借單主表 r
            JOIN 車友資料表 c ON r.車友編號 = c.車友編號
            JOIN 重型機車資料表 m ON r.車輛編號 = m.車輛編號
            ORDER BY r.租單編號 DESC
        """)
        orders = []
        for row in cursor.fetchall():
            orders.append({
                "order_id": row[0], "cust_name": row[1], "cust_uid": row[2], "cust_phone": row[3], "license": row[4],
                "bike_model": row[5], "bike_plate": row[6], 
                "start_date": row[7], 
                "expected_end_date": row[8], 
                "est_days": row[9],
                "end_date": row[10], "total_cost": row[11], "pay_method": row[12], "pay_status": row[13], "daily_rate": row[14],
                "emp_out": row[15] if row[15] else "--",
                "emp_back": row[16] if row[16] else "--",
                "emp_edit": row[17] if row[17] else "--"
            })
        conn.close()
        return jsonify(orders)
    except Exception as e:
        return jsonify({"status": "error", "message": f"讀取明細失敗：{str(e)}"}), 500

# ==============================================================================
# 4. 臨櫃點收還車 API
# ==============================================================================
@app.route('/api/return_process', methods=['POST'])
def return_process():
    data = request.json
    rental_id = data.get('rental_id')
    password = data.get('password')
    employee = data.get('employee') 
    
    if password != "admin123":
        return jsonify({"status": "error", "message": "認證失敗：安全管理密碼錯誤，拒絕回收！"}), 403
        
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        
        cursor.execute("""
            UPDATE 租借單主表 
            SET 歸還日期 = GETDATE(), 
                還車經辦 = CONCAT(?, N' (', FORMAT(GETDATE(), 'yyyy-MM-dd HH:mm:ss'), N')')
            WHERE 租單編號 = ?
        """, (employee, rental_id))
        
        conn.commit()
        conn.close()
        return jsonify({"status": "success", "message": f"重車實體回收核銷完成！點收人員：【{employee}】"})
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500

# ==============================================================================
# 5. 全權限核心修改 API
# ==============================================================================
@app.route('/api/update_order', methods=['POST'])
def update_order():
    data = request.json
    order_id = data.get('order_id')
    cust_name = data.get('cust_name')
    cust_uid = data.get('cust_uid')
    cust_phone = data.get('cust_phone')
    start_date = data.get('start_date')
    est_days = int(data.get('est_days'))
    bike_model = data.get('bike_model')
    pay_method = data.get('pay_method')
    is_returned = data.get('is_returned')
    password = data.get('password')
    employee = data.get('employee') 
    re_checkout_confirmed = data.get('re_checkout_confirmed', False) 
    
    if password != "admin123":
        return jsonify({"status": "error", "message": "權限拒絕：核心認證密碼錯誤！"}), 403
        
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        
        cursor.execute("SELECT 車友編號, 車輛編號, 總計金額 FROM 租借單主表 WHERE 租單編號 = ?", (order_id,))
        old_row = cursor.fetchone()
        cust_id, old_bike_id, old_total_cost = old_row[0], old_row[1], old_row[2]
        
        final_bike_id = old_bike_id
        cursor.execute("SELECT 車輛款式 FROM 重型機車資料表 WHERE 車輛編號 = ?", (old_bike_id,))
        old_model_name = cursor.fetchone()[0]
        
        if old_model_name != bike_model:
            cursor.execute("SELECT TOP 1 車輛編號 FROM 重型機車資料表 WHERE 車輛款式 = ? AND 車輛狀態 = N'可用'", (bike_model,))
            new_bike_row = cursor.fetchone()
            if not new_bike_row:
                conn.close()
                return jsonify({"status": "error", "message": f"調撥失敗：目標車款【{bike_model}】目前無可用空車庫存！"})
            final_bike_id = new_bike_row[0]
            cursor.execute("UPDATE 重型機車資料表 SET 車輛狀態 = N'可用' WHERE 車輛編號 = ?", (old_bike_id,))
            cursor.execute("UPDATE 重型機車資料表 SET 車輛狀態 = N'租借中' WHERE 車輛編號 = ?", (final_bike_id,))
            
        cursor.execute("SELECT 每日租金 FROM 重型機車資料表 WHERE 車輛編號 = ?", (final_bike_id,))
        daily_rate = cursor.fetchone()[0]
        new_total_cost = daily_rate * est_days
        
        if old_total_cost != new_total_cost and not re_checkout_confirmed:
            conn.close()
            return jsonify({
                "status": "need_re_checkout", 
                "old_cost": old_total_cost, 
                "new_cost": new_total_cost,
                "message": f"⚠️ 偵測到合約時程/車款異動！總租金自 ${old_total_cost} 變更為 ${new_total_cost}。\n櫃檯經辦人員必須手動核銷完成新舊差額！"
            })

        cursor.execute("UPDATE 車友資料表 SET 車友姓名=?, 身分證字號=?, 聯絡電話=? WHERE 車友編號=?", (cust_name, cust_uid, cust_phone, cust_id))
        
        if is_returned == "已還車":
            cursor.execute("""
                UPDATE 租借單主表 
                SET 車輛編號=?, 租借日期=?, 預計租借天數=?, 預計還車日期=DATEADD(day, ?, ?), 總計金額=?, 結帳方式=?, 歸還日期=GETDATE(), 
                    最後修改經辦=CONCAT(?, N' (', FORMAT(GETDATE(), 'yyyy-MM-dd HH:mm:ss'), N')'), 是否結清=N'已付清' 
                WHERE 租單編號=?
            """, (final_bike_id, start_date, est_days, est_days, start_date, new_total_cost, pay_method, employee, order_id))
        else:
            cursor.execute("""
                UPDATE 租借單主表 
                SET 車輛編號=?, 租借日期=?, 預計租借天數=?, 預計還車日期=DATEADD(day, ?, ?), 總計金額=?, 結帳方式=?, 歸還日期=NULL, 
                    最後修改經辦=CONCAT(?, N' (', FORMAT(GETDATE(), 'yyyy-MM-dd HH:mm:ss'), N')'), 是否結清=N'已付清' 
                WHERE 租單編號=?
            """, (final_bike_id, start_date, est_days, est_days, start_date, new_total_cost, pay_method, employee, order_id))
            
        conn.commit()
        conn.close()
        return jsonify({"status": "success", "message": f"租單 #{order_id} 變更並重新付款結清成功！"})
    except Exception as e:
        return jsonify({"status": "error", "message": f"SQL執行出錯：{str(e)}"}), 500

# ==============================================================================
# 6. 單筆訂單實體銷毀 API
# ==============================================================================
@app.route('/api/delete_order', methods=['POST'])
def delete_order():
    data = request.json
    password = data.get('password')
    order_id = data.get('order_id')
    employee = data.get('employee') 
    
    if password != "admin123":
        return jsonify({"status": "error", "message": "權限不足：核心管理驗證失敗！"}), 403
        
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        
        cursor.execute("SELECT 車輛編號, 歸還日期 FROM 租借單主表 WHERE 租單編號 = ?", (order_id,))
        order_row = cursor.fetchone()
        if not order_row:
            conn.close()
            return jsonify({"status": "error", "message": "找不到該筆單據！"})
            
        bike_id, return_date = order_row[0], order_row[1]
        if return_date is None:
            cursor.execute("UPDATE 重型機車資料表 SET 車輛狀態 = N'可用' WHERE 車輛編號 = ?", (bike_id,))
            
        cursor.execute("DELETE FROM 租借單主表 WHERE 租單編號 = ?", (order_id,))
        conn.commit()
        conn.close()
        return jsonify({"status": "success", "message": f"租借單 #{order_id} 已由工作人員【{employee}】安全銷毀！"})
    except Exception as e:
        return jsonify({"status": "error", "message": f"刪除失敗：{str(e)}"}), 500

# ==============================================================================
# 7. 全資料庫清空重置 API
# ==============================================================================
@app.route('/api/reset_database', methods=['POST'])
def reset_database():
    data = request.json
    password = data.get('password')
    if password != "admin123":
        return jsonify({"status": "error", "message": "核心安全驗證失敗！"}), 403
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        cursor.execute("DELETE FROM 租借單主表")
        cursor.execute("DELETE FROM 車友資料表")
        cursor.execute("UPDATE 重型機車資料表 SET 車輛狀態 = N'可用'")
        conn.commit()
        conn.close()
        return jsonify({"status": "success", "message": "SQL Server 全廠資料庫初始化完成，車輛庫存已全數釋放！"})
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500

if __name__ == '__main__':
    app.run(debug=True, port=5000)
