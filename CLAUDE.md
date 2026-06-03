# CLAUDE.md: Thiết kế Cơ sở dữ liệu - Room Service

Mục tiêu công việc là thiết kế một cơ sở dữ liệu chuyên biệt cho **Room Service** của hệ thống Homi 1.0. Thiết kế phải đảm bảo chuẩn hóa dữ liệu, hỗ trợ linh hoạt cả hai mô hình thuê theo ngày (DAILY) và theo giờ (HOURLY), đồng thời duy trì tính chính xác và toàn vẹn của dữ liệu tồn kho (availability) ngay cả khi khối lượng giao dịch lớn.

## I. Yêu cầu Chức năng

Thiết kế phải giải quyết các vấn đề sau (được tổng hợp từ Card 1 và Card 3):

### 1. Đảm bảo Độ chính xác và Kiểm soát Đồng thời

*   **Mục tiêu:** Ngăn chặn triệt để việc một phòng bị hai người cùng đặt cùng lúc (Overbooking không an toàn), đặc biệt trong môi trường có khối lượng đơn hàng lớn (100k đơn).
*   **Cơ chế:** Sử dụng **Atomic Update** trên bảng `room_availability` khi thực hiện giữ chỗ (đơn PENDING) hoặc xác nhận (đơn CONFIRMED).
    *   **Logic cập nhật (Atomic Update):**
        ```sql
        UPDATE room_availability 
        SET on_hold_units = on_hold_units + 1 
        WHERE id = :id 
        AND (total_units + overbooking_buffer - booked_units - on_hold_units) > 0 
        ```
    *   Câu lệnh update chỉ được thực thi khi "khoảng trống còn lại" lớn hơn 0, đảm bảo toàn vẹn dữ liệu.

### 2. Hỗ trợ Mô hình Thuê Linh hoạt (DAILY/HOURLY)

*   Cấu trúc dữ liệu phải hỗ trợ cả hai hình thức thuê theo ngày (`DAILY`) và theo giờ (`HOURLY`).
*   Cơ chế tính thời gian phải bao gồm thời gian dọn dẹp (`buffer_minutes`) để đảm bảo tính liên tục cho các phòng thuê theo giờ.

### 3. Đồng bộ Tồn kho với OTA (Inventory Sync)

Room Service cần hỗ trợ ba phương pháp đồng bộ để tránh Overbooking ngoài ý muốn:

1.  **iCalendar (iCal Sync):** Phương pháp cơ bản, sử dụng Cronjob chạy định kỳ (mỗi 15-30 phút) để lấy dữ liệu từ URL iCal của OTA và cập nhật vào hệ thống nội bộ. (Hạn chế: Không real-time, có độ trễ vài giờ, phù hợp với quy mô nhỏ).
2.  **Tích hợp API trực tiếp (Push/Pull):** Kết nối trực tiếp qua Connectivity API của OTA.
    *   **Push Protocol:** Hệ thống nội bộ gửi một yêu cầu POST đến API của OTA ngay khi giao dịch thành công để giảm số phòng trống.
    *   **Pull/Webhook Protocol:** OTA gửi ngược Webhook về hệ thống nội bộ khi có giao dịch xảy ra trên OTA để khóa tồn kho phòng.
3.  **Channel Manager (Khuyến nghị):** Thiết lập một cổng giao tiếp duy nhất với API Channel Manager trung tâm (SiteMinder, Channex). Đây là chuẩn hiện đại, đảm bảo đồng bộ gần real-time (dưới 5 giây).

### 4. Quản lý Trạng thái Phòng Sau Check-out

*   **Vấn đề:** Xác định khi nào một phòng trở lên khả dụng (`avai`) sau khi khách `check-out` cộng thêm thời gian dọn dẹp (`buffer_minutes`). Điều này phức tạp hơn đối với hình thức thuê theo giờ.
*   **Kiểm soát Trạng thái Phòng Thủ công:** Khi Host/Admin thay đổi trạng thái phòng (ví dụ: từ OPEN sang CLOSED), hệ thống phải đảm bảo không có đơn nào đang ở trạng thái PENDING để tránh trường hợp khách đã thanh toán nhưng phòng lại bị đóng sau đó.

### 5. Luồng Tích hợp Smartlock

*   Bảng `rooms` lưu trữ `smartlock_device_id`.
*   **Luồng Check-in Tự động:** Đối với những căn nhà có hệ thống tự động, mã khóa được mã hóa (`code_encrypted`) và cung cấp cho khách qua ứng dụng ngay khi check-in, không cần liên hệ với Host. (Dữ liệu mã hóa được lưu trữ trong bảng `smartlock_codes` của Booking Service).

---

## II. Thiết kế Schema Cơ sở dữ liệu (Các bảng của Room Service)

Thiết kế Cơ sở dữ liệu Room Service bao gồm 6 bảng chính, đảm bảo chuẩn hóa dữ liệu.

### 1. Bảng `properties` (Cơ sở Lưu trú)

Định nghĩa các cơ sở vật chất (khu căn hộ, khách sạn, chuỗi homestay).

| Column | Type | Description |
| :---: | :---: | :--- |
| **id** | UUID | PK |
| **host_id** | UUID | FK -> accounts (User Service) |
| **name** | VARCHAR | Tên cơ sở (Vd: Homi Landmark 81) |
| **is_automated** | BOOLEAN | Cờ xác định có sử dụng Smartlock tự động hay không |
| **is_dangerous** | BOOLEAN | Cờ cảnh báo (dùng để chặn các địa điểm nằm trong danh sách đen/bị báo cáo nhiều lần) |
| **address** | TEXT | Địa chỉ thực tế |

### 2. Bảng `rooms` (Cấu hình)

Định nghĩa "chức năng" và cấu hình tự động hóa của từng phòng, hỗ trợ thuê theo giờ.

| Column | Type | Constraint | Description |
| :---: | :---: | :---: | :--- |
| **id** | UUID | PK | |
| **property_id** | UUID | FK, NN | Liên kết với properties(id) |
| **rental_type** | ENUM | NN, DEF DAILY | DAILY \| HOURLY \| BOTH |
| **hourly_price** | DECIMAL(12,2) | NULLABLE | Giá theo giờ |
| **min_hours** | SMALLINT | DEF 2 | Số giờ tối thiểu yêu cầu cho một booking |
| **max_hours** | SMALLINT | NULLABLE | Giới hạn giờ tối đa (null = không giới hạn) |
| **base_price** | DECIMAL(12,2) | NN | Giá mặc định theo đêm |
| **smartlock_device_id** | VARCHAR(100) | NULLABLE | ID thiết bị Smartlock |

### 3. Bảng `room_types` (Phân loại Phòng)

Giúp chuẩn hóa dữ liệu, tiêu chuẩn hóa tiện nghi và xác định sức chứa tối đa.

| Column | Type | Description |
| :---: | :---: | :--- |
| **id** | UUID | PK |
| **property_id** | UUID | FK -> properties |
| **name** | VARCHAR | Tên loại phòng (Vd: Deluxe Studio, Suite) |
| **amenities** | TEXT\[\] | Danh sách tiện nghi (Wifi, Bồn tắm, Bếp...) |
| **max_guests** | SMALLINT | Số khách tối đa |

### 4. Bảng `room_media` (Thư viện Hình ảnh)

Quản lý khía cạnh hình ảnh của phòng, một yếu tố quan trọng để chốt đơn trên các nền tảng.

| Column | Type | Description |
| :---: | :---: | :--- |
| **id** | UUID | PK |
| **room_id** | UUID | FK -> rooms |
| **media_url** | VARCHAR | Liên kết đến hình/video (S3/Cloudinary) |
| **media_type** | ENUM | IMAGE, VIDEO |
| **is_cover** | BOOLEAN | Ảnh bìa đại diện |
| **display_order** | SMALLINT | Thứ tự hiển thị trong app |

### 5. Bảng `room_availability` (Quản lý Tồn kho)

Đóng vai trò là "người gác cổng" quản lý tình trạng phòng thực tế theo thời gian thực, ngăn chặn Overbooking. Hỗ trợ **Phân vùng theo Tháng (Monthly Partitioning)**.

| Column | Type | Constraint | Description |
| :---: | :---: | :---: | :--- |
| **id** | UUID | PK | gen_random_uuid() |
| **room_id** | UUID | FK, NN, IDX | Liên kết với rooms(id) |
| **date** | DATE | NN, IDX | Ngày cụ thể (YYYY-MM-DD) |
| **start_time** | TIME | NN | Giờ bắt đầu slot (00:00 cho thuê theo ngày) |
| **end_time** | TIME | NN | Giờ kết thúc slot (23:59 cho thuê theo ngày) |
| **slot_type** | ENUM | NN | DAILY \| HOURLY |
| **total_units** | SMALLINT | NN | Tổng số phòng cùng loại |
| **booked_units** | SMALLINT | NN, DEF 0 | Số đơn đã CONFIRMED |
| **on_hold_units** | SMALLINT | NN, DEF 0 | Số đơn đang PENDING (đã giữ chỗ) |
| **overbooking_buffer** | SMALLINT | DEF 0 | Cho phép bán quá số phòng (Homestay = 0) |
| **buffer_minutes** | SMALLINT | DEF 30 | Thời gian dọn dẹp giữa 2 booking |
| **price_override** | DECIMAL(12,2) | NULLABLE | Giá cho slot này (null = dùng giá cơ bản) |
| **status** | ENUM | NN, DEF OPEN | OPEN \| CLOSED \| BLOCKED |
| **created_at** | TIMESTAMPTZ | DEF now() | |

*   **UNIQUE constraint:** `(room_id, date, start_time, slot_type)`
*   **Composite index:** `(room_id, date, start_time, status)`
*   **Logic truy vấn tồn kho:** `SELECT room_id FROM room_availability WHERE date BETWEEN '15' AND '20' AND (total_units + overbooking_buffer - booked_units - on_hold_units) > 0 AND status = 'OPEN'`

### 6. Bảng `create_room_requests` (Quy trình Phê duyệt)

Đảm bảo chất lượng bằng cách yêu cầu Admin phê duyệt trước khi một phòng được đăng bán.

| Column | Type | Description |
| :---: | :---: | :--- |
| **id** | UUID | PK |
| **host_id** | UUID | FK -> accounts (User Service) |
| **property_data** | JSONB | Lưu trữ tất cả thông tin phòng do Host nhập |
| **status** | ENUM | PENDING, APPROVED, REJECTED |
| **admin_note** | TEXT | Lý do từ chối (nếu có) |
| **reviewed_at** | TIMESTAMPTZ | Thời điểm Admin phê duyệt |

---

## III. Cơ chế Kiểm soát Đồng thời (Concurrency & Lock)

Để giải quyết vấn đề trùng booking trong môi trường lưu lượng cao, hệ thống Homi 1.0 sẽ triển khai một giải pháp kết hợp sử dụng **Distributed Lock (Redis)** và **Pessimistic Locking (DB)**.

### 1. So sánh các Cơ chế Khóa (Khi chỉ còn 1 phòng)

| Cơ chế | Cách hoạt động | Ưu điểm | Nhược điểm |
| :---: | :--- | :--- | :--- |
| **Pessimistic Locking** | Giữ chìa khóa ngay khi khách hỏi. Người đầu tiên lấy chìa khóa, những người sau đợi ngay trước cửa. | An toàn tuyệt đối. Không bao giờ xảy ra đặt phòng trùng. | Chậm. Nếu người giữ chìa khóa nán lại quá lâu, hàng dài người chờ sẽ gây tắc nghẽn (DB congestion). |
| **Optimistic Locking** | Cho phép tất cả mọi người kiểm tra. Người nhanh nhất viết tên vào sổ trước. Người đến sau sẽ bị từ chối nếu sổ đã đầy. | Nhanh. Không ai phải xếp hàng chờ. Tận dụng tối đa sức mạnh của DB. | Dễ thất bại. Nếu 100 người "xông vào" giành 1 phòng trong đợt Flash sale, 99 người sẽ nhận lỗi "thử lại", tạo ra xung đột lớn (Retry storm). |
| **Distributed Lock (Redis)** | Đặt một máy lấy số ở cửa khách sạn. Chỉ những người có số mới được gặp lễ tân. | Phản hồi cực nhanh. Người không có số rời đi ngay lập tức, không làm phiền lễ tân (DB). | Phụ thuộc vào bên thứ ba. Nếu máy lấy số (Redis) hỏng, bảo vệ sẽ không biết để cho ai vào. |

### 2. Giải pháp Kết hợp

*   **Distributed Lock (Redis):** Kiểm tra `Idempotency-Key`. Nếu key đã tồn tại (người dùng đã nhấn đặt/trả trước đó), hệ thống từ chối các yêu cầu trùng lặp (duy trì phản hồi cực nhanh cho người dùng).
*   **Pessimistic Locking (DB):** Khi Client mang key đến DB, `Pessimistic Locking` thực hiện `SELECT FOR UPDATE` để khóa dòng trong bảng `room_availability`. Điều này đảm bảo không có giao dịch nào khác có thể chen ngang và thay đổi số lượng phòng trong khi đang tính toán.

### 3. KIẾN TRÚC BOOKING 2 GIAO DỊCH

Cơ chế này chia quy trình booking thành **hai giai đoạn riêng biệt** để tối ưu hiệu năng DB và trải nghiệm người dùng.

#### Giai đoạn 1: Giữ chỗ tạm thời

*   **Thời điểm:** Ngay lập tức khi người dùng nhấn nút "Thanh toán".
*   **Hành động tại DB:**
    1.  Mở một Transaction, thực hiện **Pessimistic Lock** (`SELECT FOR UPDATE`) trên bảng `room_availability` để kiểm tra số phòng một cách độc quyền.
    2.  Nếu còn phòng: Tăng `booked_units` lên 1 đơn vị.
    3.  Tạo một bản ghi trong bảng `bookings` với trạng thái `PENDING_PAYMENT`, đính kèm `Idempotency-Key` để chống trùng lặp.
*   **Kết luận:** Thực thi `COMMIT` ngay lập tức. Lock chỉ tồn tại trong vài phần nghìn giây.

#### Giai đoạn trung gian: Chờ thanh toán

*   **Thời điểm:** Màn hình hiển thị mã VietQR (thường cho phép từ 10-15 phút).
*   **Trạng thái Lock:** Tuyệt đối không có Lock nào trong DB; các kết nối hoàn toàn rảnh rỗi.
*   **Trải nghiệm người dùng tiếp theo:** Nếu một người khác cố gắng đặt cùng phòng, DB sẽ báo "Hết phòng" dựa trên số `booked_units` đã được cập nhật, không phải do "bị kẹt" chờ Lock.

#### Giai đoạn 2: Hoàn tất hoặc Hoàn tác

Xử lý dựa trên kết quả thanh toán thực tế từ khách hàng.

**1. Thanh toán Thất bại hoặc Bị hủy (Lỗi Real-time)**
*   **Xử lý:** Backend nhận tín hiệu, ngay lập tức mở một Transaction rất ngắn để:
    *   Chuyển trạng thái Booking thành `CANCELLED`.
    *   Giảm `booked_units` xuống 1 đơn vị (Trả phòng về kho tồn).

**2. Khách "Lặng lẽ" Rời đi**
*   **Xử lý:** Sử dụng Cron Job (chạy mỗi 5-10 phút) để quét các đơn `PENDING_PAYMENT` đã hết hạn (ví dụ: 10 phút).
    *   Tự động hủy đơn và cộng phòng trở lại dữ liệu tồn kho.

### 4. Hiệu quả của Cơ chế 2 Giao dịch

1.  **Chống tắc nghẽn (Không Bottleneck):** DB không bao giờ bị khóa quá 0.1 giây. Hệ thống chạy cực kỳ mượt mà ngay cả khi lưu lượng truy cập cao.
2.  **Chính xác (Nhất quán):** Nhờ `SELECT FOR UPDATE` ngắn hạn ở Giai đoạn 1, số lượng phòng được kiểm soát chặt chẽ, đảm bảo không bán quá số phòng (Overbooking).
3.  **Tối ưu Tài nguyên:** Server của bạn có thể xử lý hàng trăm khách hàng cùng lúc vì không phải "gánh" các kết nối DB bị giữ quá lâu.
