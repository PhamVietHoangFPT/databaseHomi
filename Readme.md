# Homi 1.0 — Báo Cáo Thiết Kế Database Dịch Vụ Phòng (Room Service)

---

## Mục lục

1. [Phân tích ERD từng trường](#1-phân-tích-erd-từng-trường)
2. [Kiến trúc Microservice & Cải tiến Hệ thống](#2-kiến-trúc-microservice--cải-tiến-hệ-thống)
3. [Khuyến nghị Công nghệ cho NestJS](#3-khuyến-nghị-công-nghệ-cho-nestjs)

---

## 1. Phân tích ERD từng trường

### 1.1 Bảng `properties` — Thông tin Cơ sở Lưu trú

Bảng này đại diện cho một thực thể vật lý (khách sạn, homestay, căn hộ, biệt thự) thuộc quyền quản lý của một Host. Việc tách riêng `properties` khỏi `rooms` tuân thủ chuẩn **3NF (Third Normal Form)** — tránh lặp dữ liệu (property name, address, host) khi một property có nhiều phòng.

| Trường | Kiểu dữ liệu | Ràng buộc | Mô tả kỹ thuật |
|--------|-------------|-----------|----------------|
| `id` | `UUID` | PK | Định danh duy nhất toàn cục. Dùng UUID v7 (timestamp-ordered) để đảm bảo tính **globally unique** trong kiến trúc phân tán, tránh collision giữa các service khi sinh ID đồng thời. UUID v7 **không random**, byte đầu chứa timestamp, giúp B-tree index hiệu quả hơn so với UUID v4 random. |
| `host_id` | `UUID` | **Không có FK** | Chỉ lưu UUID tham chiếu đến `accounts(id)` trong User Service. **Không thiết lập FK cứng** vì đây là cross-service reference — FK cứng sẽ gây coupled deployment và cascade delete không kiểm soát được. Xử lý consistency bằng tầng ứng dụng hoặc event. |
| `name` | `VARCHAR(255)` | NOT NULL | Tên hiển thị của cơ sở lưu trú (VD: "Homi Landmark 81", "Biệt thự Biển Đà Nẵng"). Dùng cho app hiển thị và đồng bộ lên OTA. |
| `is_automated` | `BOOLEAN` | NOT NULL, DEFAULT `false` | Cờ xác định cơ sở có sử dụng **Smartlock tự động** hay không. Nếu `true`, hệ thống sẽ tự động sinh mã khóa, mã hóa AES-256-GCM và gửi cho guest qua app. Nếu `false`, Host phải gửi mã thủ công. Trường này là **logic branch** quan trọng trong smartlock flow. |
| `is_dangerous` | `BOOLEAN` | NOT NULL, DEFAULT `false` | Cờ an toàn. Khi `true`, property bị blacklist hoặc có báo cáo vi phạm liên tiếp. Hệ thống sẽ **khóa toàn bộ booking mới** và ẩn khỏi kết quả tìm kiếm. Dùng cho việc vetting Host và compliance. |
| `address` | `TEXT` | NOT NULL | Địa chỉ đầy đủ. Dùng `TEXT` thay vì `VARCHAR` vì địa chỉ có độ dài rất khác nhau giữa các quốc gia, có thể chứa nhiều dòng, và cần lưu format gốc không bị cắt. |

---

### 1.2 Bảng `rooms` — Cấu hình Phòng

Định nghĩa các thuộc tính chức năng và giá của từng phòng. Hỗ trợ cả hai mô hình DAILY và HOURLY trong **một bảng duy nhất**, tránh schema duplication.

| Trường | Kiểu dữ liệu | Ràng buộc | Mô tả kỹ thuật |
|--------|-------------|-----------|----------------|
| `id` | `UUID` | PK | Định danh duy nhất của phòng. |
| `property_id` | `UUID` | FK → `properties(id)`, NOT NULL | Khóa ngoại nội service — hoàn toàn hợp lệ vì cùng thuộc Room Service. Đảm bảo referential integrity trong phạm vi một service. |
| `rental_type` | `ENUM` | NOT NULL, DEFAULT `'DAILY'` | Xác định mô hình cho thuê. `DAILY` = lưu trú qua đêm, `HOURLY` = tính theo giờ (VD: không gian làm việc, khách sạn theo giờ), `BOTH` = hỗ trợ cả hai. Đây là **quyết định thiết kế lõi**, tránh phải tạo hai bảng riêng. |
| `hourly_price` | `DECIMAL(12,2)` | NULLABLE | Giá theo giờ cho phòng HOURLY hoặc BOTH. NULLABLE vì phòng DAILY-only không cần trường này — tránh dùng giá trị giả `0`. |
| `min_hours` | `SMALLINT` | DEFAULT `2` | Thời gian thuê tối thiểu (giờ) cho chế độ HOURLY. Ngăn chặn đặt phòng 1 giờ — không khả thi về mặt thương mại. Default 2 giờ là chuẩn phổ biến cho không gian làm việc / khách sạn theo giờ. |
| `max_hours` | `SMALLINT` | NULLABLE | Thời gian thuê tối đa. NULL = không giới hạn. Dùng để ngăn guest đặt 24 giờ trên phòng HOURLY (vi phạm mô hình giá). |
| `base_price` | `DECIMAL(12,2)` | NOT NULL | Giá qua đêm mặc định cho booking DAILY. Đây là giá fallback — ngày đặc biệt sẽ override qua `room_availability.price_override`. |
| `smartlock_device_id` | `VARCHAR(100)` | NULLABLE | Device ID từ nhà cung cấp Smartlock (VD: igloohome, Yale, Tesa). NULL = phòng dùng khóa vật lý hoặc Host tự quản lý. Lưu tại đây (không phải trong `room_availability`) vì thiết bị gắn với phòng, không phải ngày. |

> **Tại sao không lưu giá trực tiếp trong `room_availability`?**
> Vì `room_availability` được partition theo ngày và có tần suất ghi rất cao. Lưu giá base ở đây sẽ lặp lại trên mọi row. Thay vào đó, `base_price` / `hourly_price` trong `rooms` là giá mặc định; chỉ các ngoại lệ (giá event đặc biệt) mới vào `price_override`.

---

### 1.3 Bảng `room_types` — Phân loại Phòng

Chuẩn hóa phân loại phòng trong một property. Cho phép gom nhóm tiện nghi và lọc theo sức chứa.

| Trường | Kiểu dữ liệu | Ràng buộc | Mô tả kỹ thuật |
|--------|-------------|-----------|----------------|
| `id` | `UUID` | PK | Định danh duy nhất của loại phòng. |
| `property_id` | `UUID` | FK → `properties(id)` | Property cha. Mỗi room_type thuộc về một property. |
| `name` | `VARCHAR(100)` | NOT NULL | Tên loại phòng hiển thị cho khách (VD: "Deluxe Studio", "Ocean View Suite", "Standard Twin"). |
| `amenities` | `TEXT[]` (PostgreSQL array) | NULLABLE | Mảng từ khóa tiện nghi. Dùng native `TEXT[]` của PostgreSQL thay vì bảng trung gian nhiều-nhiều — đơn giản hơn, query nhanh hơn (`WHERE 'Wifi' = ANY(amenities)`), và tránh JOIN phức tạp cho danh sách tương đối tĩnh. |
| `max_guests` | `SMALLINT` | NOT NULL | Số khách tối đa cho loại phòng này. Enforced tại tầng application khi booking để ngăn over-capacity reservation. |

---

### 1.4 Bảng `room_media` — Tài nguyên Hình ảnh / Video

Quản lý tài sản hình ảnh và video của phòng — yếu tố quan trọng ảnh hưởng trực tiếp đến **tỷ lệ chuyển đổi đơn hàng** trên các nền tảng listing.

| Trường | Kiểu dữ liệu | Ràng buộc | Mô tả kỹ thuật |
|--------|-------------|-----------|----------------|
| `id` | `UUID` | PK | Định danh duy nhất của media item. |
| `room_id` | `UUID` | FK → `rooms(id)` | Phòng cha mà media thuộc về. |
| `media_url` | `VARCHAR(500)` | NOT NULL | URL đầy đủ đến file media trên S3, Cloudinary, hoặc CDN tương tự. `VARCHAR(500)` đủ chứa presigned URL dài của S3. |
| `media_type` | `ENUM('IMAGE', 'VIDEO')` | NOT NULL | Loại media. Tách enum để dễ mở rộng về sau (VD: `VIRTUAL_TOUR`, `3D_MODEL`) mà không cần migration. |
| `is_cover` | `BOOLEAN` | NOT NULL, DEFAULT `false` | Đánh dấu thumbnail đại diện. Chỉ một media item duy nhất nên có `is_cover = true` trên mỗi phòng. Enforce ở tầng application. |
| `display_order` | `SMALLINT` | NOT NULL, DEFAULT `0` | Thứ tự hiển thị trong gallery. Số nhỏ hơn hiển thị trước. Cho phép kéo-thả reorder mà không cần đánh số lại toàn bộ các row khác. |

---

### 1.5 Bảng `room_availability` — Quản lý Tồn kho (Bảng Lõi)

**Đây là bảng quan trọng nhất của hệ thống.** Nó đóng vai trò như **sổ cái tồn kho thời gian thực**, ngăn chặn overbooking ngay cả trong môi trường khối lượng giao dịch cực lớn (100k đơn/ngày).

| Trường | Kiểu dữ liệu | Ràng buộc | Mô tả kỹ thuật |
|--------|-------------|-----------|----------------|
| `id` | `UUID` | PK | Định danh slot. Sinh bằng `gen_random_uuid()` để hỗ trợ sinh phân tán. |
| `room_id` | `UUID` | FK → `rooms(id)`, NOT NULL, IDX | Liên kết đến phòng. Indexed để lookup nhanh trong availability query. |
| `date` | `DATE` | NOT NULL, IDX | Ngày của khe thời gian (YYYY-MM-DD). Indexed cho range query (`WHERE date BETWEEN ...`). |
| `start_time` | `TIME` | NOT NULL | Thời gian bắt đầu khe. DAILY = `00:00`. HOURLY = `HH:00` (VD: `14:00`). Trường này cho phép một phòng có **nhiều khe trong cùng một ngày** ở chế độ HOURLY. |
| `end_time` | `TIME` | NOT NULL | Thời gian kết thúc khe. DAILY = `23:59`. HOURLY = `HH:59` hoặc giờ checkout thực tế. |
| `slot_type` | `ENUM('DAILY', 'HOURLY')` | NOT NULL | Phân biệt mô hình thuê ở cấp độ khe. Cần thiết vì phòng `BOTH` có thể được đặt theo hai cách, và hệ thống cần theo dõi tồn kho riêng biệt cho từng mode. |
| `total_units` | `SMALLINT` | NOT NULL | Tổng số phòng giống nhau cho khe này. VD: khách sạn có 5 phòng "Standard Double" cùng ngày → 1 row với `total_units = 5`. **Thiết kế khuyến nghị:** mỗi row = 1 phòng vật lý, `total_units = 1`. Query theo room_type sẽ `GROUP BY`. |
| `booked_units` | `SMALLINT` | NOT NULL, DEFAULT `0` | Số phòng đã có **CONFIRMED booking**. Chỉ tăng khi thanh toán thành công. Đây là số "đã bán". |
| `on_hold_units` | `SMALLINT` | NOT NULL, DEFAULT `0` | Số phòng đang giữ bởi đơn **PENDING_PAYMENT** (chờ thanh toán VietQR). Đây là phòng đã reserve nhưng chưa thanh toán. Được giải phóng khi payment fail hoặc timeout. |
| `overbooking_buffer` | `SMALLINT` | DEFAULT `0` | Số phòng cho phép bán vượt `total_units` (bán thêm có chủ đích). Homestay = 0 (không bao giờ oversell). Khách sạn có thể đặt 1-2 để bù no-show. Đây là **trường nghiệp vụ**, không phải bug. |
| `buffer_minutes` | `SMALLINT` | DEFAULT `30` | Thời gian dọn dẹp (phút) giữa hai booking liên tiếp. Với phòng HOURLY, trường này tạo khoảng gap bắt buộc giữa các khe. Với phòng DAILY, đây là thời gian sau checkout trước khi guest tiếp theo check-in. |
| `price_override` | `DECIMAL(12,2)` | NULLABLE | Ghi đè giá cho khe này. NULL = dùng giá mặc định từ `rooms`. VD: giá Tết, giá event đặc biệt. |
| `status` | `ENUM('OPEN', 'CLOSED', 'BLOCKED')` | NOT NULL, DEFAULT `'OPEN'` | `OPEN` = sẵn sàng nhận booking. `CLOSED` = Host/Admin chủ động đóng. `BLOCKED` = hệ thống khóa (bảo trì, vi phạm chính sách). Phòng CLOSED không thể nhận booking bất kể tồn kho còn bao nhiêu. |
| `version` | `INT` | DEFAULT `1` | Trường optimistic lock. Mỗi UPDATE tăng version. Khi đọc rồi ghi, ứng dụng kiểm tra version để phát hiện **concurrent modification** — tầng bảo vệ thứ hai sau pessimistic lock. |
| `created_at` | `TIMESTAMPTZ` | DEFAULT `now()` | Timestamp tạo bản ghi. Dùng cho audit và debug. |
| `updated_at` | `TIMESTAMPTZ` | DEFAULT `now()` | Timestamp cập nhật cuối. **Bắt buộc** cho cache invalidation — khi row thay đổi, Redis cache có thể invalidate tự động. |

**Các ràng buộc và chỉ mục quan trọng:**

```sql
-- Ràng buộc DUY NHẤT: đảm bảo không có khe trùng lặp
UNIQUE (room_id, date, start_time, slot_type)

-- Chỉ mục COMPOSITE: phục vụ query tìm phòng trống nhanh
CREATE INDEX idx_room_availability_lookup
    ON room_availability (room_id, date, start_time, status)
    WHERE status = 'OPEN';

-- Công thức tính sẵn có (inventory gatekeeper)
(total_units + overbooking_buffer - booked_units - on_hold_units) > 0
```

---

### 1.6 Bảng `create_room_requests` — Quy trình Phê duyệt Phòng Mới

Theo dõi vòng đời submission và review để tạo phòng mới. Đảm bảo chất lượng trước khi phòng lên sàn.

| Trường | Kiểu dữ liệu | Ràng buộc | Mô tả kỹ thuật |
|--------|-------------|-----------|----------------|
| `id` | `UUID` | PK | Định danh yêu cầu. |
| `host_id` | `UUID` | Không có FK | UUID tham chiếu đến User Service. Không thiết lập FK vì cross-service. |
| `property_data` | `JSONB` | NOT NULL | Snapshot toàn bộ dữ liệu phòng Host nhập. Lưu dưới dạng JSON document để: (1) form tiến hóa không cần migration, (2) khi bị từ chối, Host có thể chỉnh sửa và resubmit mà không cần nhập lại. |
| `status` | `ENUM('PENDING', 'APPROVED', 'REJECTED')` | NOT NULL | Trạng thái hiện tại của workflow review. |
| `admin_note` | `TEXT` | NULLABLE | Ghi chú từ Admin khi từ chối. Hướng dẫn Host sửa chữa. |
| `reviewed_at` | `TIMESTAMPTZ` | NULLABLE | Thời điểm Admin ra quyết định. NULL khi đang chờ. Dùng để tracking SLA ("review quá 48 tiếng"). |

---

### 1.7 Bảng `room_slot_bookings` — Bảng Projection Nội bộ (Room Service)

**Bảng này KHÔNG có trong thiết kế ban đầu nhưng bắt buộc phải có** trong kiến trúc microservice. Đây là **projection cục bộ** của Room Service — nó lưu trữ mối liên hệ giữa các slot tồn kho và các booking từ Booking Service bên ngoài.

| Trường | Kiểu dữ liệu | Ràng buộc | Mô tả kỹ thuật |
|--------|-------------|-----------|----------------|
| `id` | `UUID` | PK | Định danh liên kết. |
| `availability_id` | `UUID` | FK → `room_availability(id)`, NOT NULL | Liên kết đến slot tồn kho cụ thể. |
| `external_booking_id` | `UUID` | NOT NULL | UUID của booking từ Booking Service. **Không có FK** vì Booking Service là service khác. Đây là **eventual consistency** — khi nhận event `BOOKING_CONFIRMED`, Room Service ghi nhận booking ID vào đây. |
| `status` | `ENUM('PENDING', 'CONFIRMED', 'CANCELLED', 'EXPIRED')` | NOT NULL | Trạng thái booking tại tầng Room Service. Đồng bộ với `bookings.status` của Booking Service qua event. |
| `guest_id` | `UUID` | NOT NULL | UUID của guest. Không có FK cross-service. |
| `check_in_at` | `TIMESTAMPTZ` | NULLABLE | Thời điểm guest thực sự check-in (mở khóa thành công). Được cập nhật khi nhận event `CHECKIN_COMPLETED` từ Booking Service. |
| `check_out_at` | `TIMESTAMPTZ` | NULLABLE | Thời điểm guest check-out. |
| `created_at` | `TIMESTAMPTZ` | DEFAULT `now()` | |

> **Tại sao Room Service cần bảng riêng?**
> Vì Room Service và Booking Service không dùng chung database. Room Service cần một bản ghi cục bộ để: (1) biết slot nào đang map với booking nào, (2) query "có booking đang hoạt động cho phòng X ngày Y không" (cần cho state-transition guard), (3) audit vòng đời đầy đủ của một slot.

---

### 1.8 Bảng `room_booking_events` — Outbox Pattern (Room Service)

Triển khai **Transactional Outbox Pattern** — đảm bảo mọi thay đổi trạng thái đều được phát event một cách đáng tin cậy, ngay cả khi message broker tạm thời không khả dụng.

| Trường | Kiểu dữ liệu | Ràng buộc | Mô tả kỹ thuật |
|--------|-------------|-----------|----------------|
| `id` | `UUID` | PK | Định danh event. |
| `aggregate_type` | `VARCHAR(50)` | NOT NULL | Loại aggregate: `'availability'`, `'slot_booking'`, `'room'`. Dùng để filter khi xử lý outbox. |
| `aggregate_id` | `UUID` | NOT NULL | ID của aggregate bị ảnh hưởng. |
| `event_type` | `VARCHAR(50)` | NOT NULL | Tên event: `ROOM_AVAILABILITY_RESERVED`, `ROOM_AVAILABILITY_CONFIRMED`, `ROOM_AVAILABILITY_RELEASED`, `ROOM_STATUS_CHANGED`. |
| `payload` | `JSONB` | NOT NULL | Dữ liệu event — chứa đầy đủ thông tin để consumer xử lý idempotent. |
| `status` | `ENUM('PENDING', 'PUBLISHED', 'FAILED')` | NOT NULL, DEFAULT `'PENDING'` | Trạng thái xuất bản. `PENDING` = chờ relay. `PUBLISHED` = đã gửi broker thành công. `FAILED` = cần retry. |
| `retry_count` | `SMALLINT` | DEFAULT `0` | Số lần retry. Nếu vượt ngưỡng (VD: 5 lần), chuyển sang `FAILED` và alert Admin. |
| `created_at` | `TIMESTAMPTZ` | DEFAULT `now()` | Thời điểm event được tạo — nằm trong cùng transaction với thay đổi data. |
| `published_at` | `TIMESTAMPTZ` | NULLABLE | Thời điểm event thực sự được publish lên broker. |

---

## 2. Kiến trúc Microservice & Cải tiến Hệ thống

### 2.1 Phân tích Kiến trúc Microservice

#### 2.1.1 Nguyên tắc Phân tách Database (Database per Service)

Mỗi bounded context sở hữu database riêng. Đây là nguyên tắc cốt lõi của microservice — **shared database anti-pattern** (dùng chung DB giữa các service) dẫn đến:

- **Coupled deployment**: thay đổi schema ở service A có thể break service B
- **Cascade delete không kiểm soát**: xóa user có thể ảnh hưởng booking không mong muốn
- **Khó scale riêng**: service A có thể cần nhiều resource hơn service B nhưng phải share CPU/RAM

```
Room Service (PostgreSQL riêng)
  ├── properties          (cơ sở lưu trú)
  ├── rooms               (cấu hình phòng)
  ├── room_types          (phân loại)
  ├── room_media          (hình ảnh/video)
  ├── room_availability   (tồn kho)
  ├── room_slot_bookings  (projection nội bộ)
  └── room_booking_events (outbox)

Booking Service (PostgreSQL riêng)
  ├── bookings                (đơn đặt phòng)
  ├── smartlock_codes         (mã khóa)
  ├── booking_cancellations   (hủy booking)
  └── booking_status_events    (outbox)

User Service (PostgreSQL riêng)
  ├── accounts
  ├── host_profiles
  ├── guest_profiles
  └── admin_profiles
```

#### 2.1.2 Xử lý Cross-Service Reference

Trong kiến trúc microservice, **không có FK cứng giữa các service**. Cách xử lý:

| Tình huống | Cách giải quyết |
|-----------|----------------|
| Room Service cần biết Host nào sở hữu property | Lưu `host_id` (UUID) trong `properties`. Khi cần thông tin chi tiết Host → gọi User Service API. |
| Room Service cần xác định active bookings để chặn close room | Dùng bảng `room_slot_bookings` nội bộ, đồng bộ qua event từ Booking Service. |
| Booking Service cần biết thông tin phòng | Lưu `room_id` (UUID) trong `bookings`. Khi cần thông tin chi tiết phòng → gọi Room Service API. |
| Smartlock code cần device_id từ Room Service | Booking Service nhận `smartlock_device_id` từ payload event hoặc gọi Room Service API. |

#### 2.1.3 Event-Driven Communication (Giao tiếp qua Event)

Thay vì gọi trực tiếp database cross-service, các service giao tiếp qua **message broker** (Kafka hoặc RabbitMQ). Đây là **asynchronous, eventual consistency**.

```
┌──────────────┐    ROOM_AVAILABILITY_RESERVED    ┌────────────────┐
│ Room Service  │ ──────────────────────────────→  │ Booking Service│
│              │    ROOM_AVAILABILITY_CONFIRMED   │                │
│              │ ←──────────────────────────────── │                │
│              │    BOOKING_CONFIRMED              │                │
│              │ ←──────────────────────────────── │                │
│              │    BOOKING_CANCELLED              │                │
│              │ ←──────────────────────────────── │                │
└──────────────┘                                   └────────────────┘
         ↑                                                   ↑
         │          CHECKIN_COMPLETED                        │
         │ ──────────────────────────────────────────────────┤
         │          CHECKOUT_COMPLETED                       │
         └──────────────────────────────────────────────────┘
```

#### 2.1.4 Transactional Outbox Pattern — Chi tiết

**Vấn đề:** Khi booking được confirm, Room Service cần cập nhật `room_availability` VÀ gửi event đến Booking Service. Nếu cập nhật DB xong mà gửi message broker fail → hệ thống inconsistent.

**Giải pháp:** Thay vì gửi trực tiếp broker, ghi vào `room_booking_events` trong **cùng một transaction** với thay đổi data:

```sql
-- Trong một transaction DUY NHẤT
BEGIN;
  UPDATE room_availability
  SET booked_units = booked_units + 1,
      on_hold_units = on_hold_units - 1,
      version = version + 1,
      updated_at = now()
  WHERE id = :id;

  UPDATE room_slot_bookings
  SET status = 'CONFIRMED'
  WHERE availability_id = :id;

  INSERT INTO room_booking_events
    (aggregate_type, aggregate_id, event_type, payload, status, created_at)
  VALUES
    ('availability', :id, 'ROOM_AVAILABILITY_CONFIRMED',
     '{"booking_id": "uuid", "room_id": "uuid", "date": "2026-05-20"}',
     'PENDING', now());
COMMIT;
-- Transaction đảm bảo: hoặc cả 3 thao tác đều thành công, hoặc đều rollback
```

Sau đó, một **Outbox Relay process** (BullMQ worker hoặc cron) đọc các row có `status = 'PENDING'`, publish lên broker, rồi cập nhật `status = 'PUBLISHED'`.

---

### 2.2 Các Bảng Còn Thiếu

#### 2.2.1 Bảng `room_maintenance` — Lịch trình Bảo trì

**Vấn đề:** Trường `status = BLOCKED` trên `room_availability` chỉ là cờ tĩnh. Không có cách có cấu trúc để lên lịch bảo trì, thông báo cho khách bị ảnh hưởng, hoặc phân biệt "blocked do bảo trì" vs "blocked do vi phạm chính sách".

```sql
CREATE TABLE room_maintenance (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    room_id         UUID NOT NULL REFERENCES rooms(id),
    start_at        TIMESTAMPTZ NOT NULL,
    end_at          TIMESTAMPTZ,                    -- NULL = vô thời hạn
    reason          VARCHAR(255) NOT NULL,           -- "Sửa ống nước", "Sơn lại"
    is_guest_notified BOOLEAN DEFAULT false,
    created_by      UUID NOT NULL,                  -- Host hoặc Admin UUID
    created_at      TIMESTAMPTZ DEFAULT now()
);

-- Trigger: khi tạo maintenance, tự động BLOCK các slot trùng thời gian
-- Tự động mở lại OPEN các slot khi maintenance kết thúc
```

#### 2.2.2 Bảng `pricing_rules` — Công cụ Định giá Động

**Vấn đề:** `room_availability.price_override` chỉ xử lý override đơn lẻ. Một engine định giá thực sự cần rules có cấu trúc.

```sql
CREATE TABLE pricing_rules (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    room_id           UUID REFERENCES rooms(id),    -- NULL = property-wide
    property_id       UUID REFERENCES properties(id),
    rule_type        VARCHAR(50) NOT NULL,         -- WEEKEND_SURCHARGE,
                                                  -- SEASONAL, LAST_MINUTE, LOS_DISCOUNT
    condition_json    JSONB NOT NULL,              -- {"day_of_week": [6, 7]}
                                                  -- {"hours_before_checkin": "<= 24"}
    adjustment_type   VARCHAR(20) NOT NULL,        -- PERCENTAGE | FIXED_AMOUNT
    adjustment_value  DECIMAL(12,2) NOT NULL,      -- +20 hoặc +50000 VND
    priority          SMALLINT DEFAULT 0,          -- Cao hơn thắng khi rules overlap
    is_active         BOOLEAN DEFAULT true,
    created_at        TIMESTAMPTZ DEFAULT now()
);

-- Cú pháp tính giá tại thời điểm booking:
-- final_price = base_price × (1 + Σ percentage_adjustments) + Σ fixed_adjustments
```

#### 2.2.3 Bảng `booking_cancellations` — Audit Hủy Booking

**Vấn đề:** Khi booking bị hủy (bởi guest, Host, Admin hoặc SYSTEM), không có bản ghi có cấu trúc về lý do, số tiền hoàn, và cancellation policy được áp dụng.

```sql
CREATE TABLE booking_cancellations (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    booking_id            UUID NOT NULL UNIQUE REFERENCES bookings(id),
    cancelled_by          VARCHAR(20) NOT NULL,   -- GUEST | HOST | ADMIN | SYSTEM
    cancellation_reason   TEXT,
    cancellation_policy   VARCHAR(255),            -- "Miễn phí hủy trong 24h"
    refund_amount         DECIMAL(12,2),
    refund_status         VARCHAR(20) DEFAULT 'PENDING', -- PENDING | PROCESSED | FAILED
    cancelled_at          TIMESTAMPTZ DEFAULT now(),
    inventory_restored_at TIMESTAMPTZ              -- Khi booked_units được giảm
);
```

#### 2.2.4 Bảng `inventory_sync_log` — Audit Đồng bộ OTA

**Vấn đề:** Quá trình iCal sync không có audit trail. Khi OTA đẩy dữ liệu sai, không có cách trace sync nào gây ra vấn đề.

```sql
CREATE TABLE inventory_sync_log (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_type       VARCHAR(30) NOT NULL,   -- ICAL | DIRECT_API | CHANNEL_MANAGER
    source_url        VARCHAR(500),
    property_id       UUID REFERENCES properties(id),
    sync_type         VARCHAR(10) NOT NULL,   -- PULL | PUSH
    events_received   INT DEFAULT 0,
    events_applied    INT DEFAULT 0,
    events_failed     INT DEFAULT 0,
    error_message     TEXT,
    synced_at         TIMESTAMPTZ DEFAULT now()
);
```

#### 2.2.5 Bảng `room_access_logs` — Audit Truy cập Smartlock

**Vấn đề:** Hệ thống ghi nhận `check_in_at` / `check_out_at` nhưng không capture toàn bộ sự kiện mở khóa. Cần audit trail đầy đủ cho bảo mật và giải quyết tranh chấp.

```sql
CREATE TABLE room_access_logs (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    booking_id      UUID REFERENCES bookings(id),
    device_id       VARCHAR(100) NOT NULL,
    event_type      VARCHAR(30) NOT NULL,    -- UNLOCK | LOCK | FAILED_ATTEMPT | MANUAL_OVERRIDE
    unlock_method   VARCHAR(30),              -- PIN | BLE | FINGERPRINT | PHYSICAL_KEY
    occurred_at     TIMESTAMPTZ NOT NULL,
    metadata        JSONB                    -- {"battery_level": 72, "signal_strength": -45}
);
```

---

### 2.3 Cải tiến Cấp Database

#### 2.3.1 Partial Index cho Query Tìm Phòng Trống

```sql
-- Partial index: chỉ index các slot OPEN
-- Kích thước nhỏ hơn đáng kể so với index toàn bộ bảng
CREATE INDEX idx_room_availability_open
    ON room_availability (room_id, date, start_time)
    WHERE status = 'OPEN';

-- Benchmark: bảng 10 triệu row, partial index có thể nhỏ hơn 90%
-- so với full index trên cùng các cột
```

#### 2.3.2 Table Partitioning theo Tháng

```sql
-- Partition bằng RANGE trên date
CREATE TABLE room_availability (
    id UUID,
    room_id UUID,
    date DATE NOT NULL,
    -- ... các trường khác
) PARTITION BY RANGE (date);

-- Tạo partition cho từng tháng
CREATE TABLE room_availability_2026_05
    PARTITION OF room_availability
    FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');

-- Query trên partition: PostgreSQL tự động PRUNE partition không liên quan
-- giảm I/O đáng kể cho range query
```

**Chính sách archive:** Các partition cũ hơn tháng hiện tại + 2 tháng được move sang **archive schema** (read-only). Đảm bảo hot data luôn nhanh, old data vẫn query được khi cần.

#### 2.3.3 Row-Level Security (RLS) cho Multi-Tenant

```sql
-- Bật RLS trên các bảng nhạy cảm
ALTER TABLE room_availability ENABLE ROW LEVEL SECURITY;

-- Chính sách: Host chỉ thấy property của mình
CREATE POLICY host_own_availability ON room_availability
    USING (
        room_id IN (
            SELECT id FROM rooms
            WHERE property_id IN (
                SELECT id FROM properties
                WHERE host_id = current_setting('app.current_user_id')::UUID
            )
        )
    );
```

#### 2.3.4 Advisory Lock cho Multi-Room Booking

Khi guest đặt nhiều phòng cùng lúc (VD: đặt 3 phòng), atomic UPDATE trên một row không đủ. Dùng **advisory lock** của PostgreSQL:

```sql
-- Khóa trên danh sách room_id cụ thể
SELECT pg_advisory_xact_lock(hashtext(room_id_1 || date_1));
SELECT pg_advisory_xact_lock(hashtext(room_id_2 || date_2));

-- Thực hiện multi-row UPDATE
UPDATE room_availability SET booked_units = booked_units + 1
WHERE id IN (:id1, :id2);

-- Lock tự động giải phóng khi transaction kết thúc
-- Nhẹ hơn SELECT FOR UPDATE trên nhiều row
```

#### 2.3.5 JSONB Indexing cho Query Linh Hoạt

```sql
-- GIN index trên amenities: tìm phòng có Wifi và Bồn tắm
CREATE INDEX idx_room_types_amenities
    ON room_types USING GIN (amenities);

-- GIN index trên property_data: tìm kiếm trong form submission
CREATE INDEX idx_create_room_requests_data
    ON create_room_requests USING GIN (property_data);

-- B-tree index trên status + created_at: lọc request theo trạng thái
CREATE INDEX idx_create_room_requests_status
    ON create_room_requests (status, created_at);
```

---

### 2.4 Cải tiến Cấp Ứng dụng

#### 2.4.1 Idempotency Key Persistence

Redis SETNX có thể fail (Redis down, restart). Cần **persistent backup** trong PostgreSQL:

```sql
CREATE TABLE idempotency_keys (
    key         VARCHAR(255) PRIMARY KEY,
    booking_id  UUID NOT NULL,
    created_at  TIMESTAMPTZ DEFAULT now(),
    expires_at  TIMESTAMPTZ DEFAULT now() + INTERVAL '15 minutes'
);

-- Cleanup: DELETE FROM idempotency_keys WHERE expires_at < now();
-- Chạy mỗi 5 phút bằng BullMQ recurring job
```

Flow: Check Redis trước → nếu miss → check PostgreSQL → nếu tìm thấy → reject. Đảm bảo idempotency ngay cả khi Redis không khả dụng.

#### 2.4.2 Circuit Breaker cho OTA API Calls

Khi gọi OTA API (Channel Manager), nếu OTA bị downtime, các request pending sẽ tích lũy và gây cascade failure. Dùng **Circuit Breaker**:

```
Closed (bình thường)
  → Khi error rate > 50% trong 10s → Open (ngắt)
  → Sau 30s → Half-Open (thử phục hồi)
  → Thành công → Closed
  → Thất bại → Open lại
```

Triển khai bằng thư viện `opossum` cho Node.js:

```typescript
const circuitBreaker = require('opossum');
const options = {
  timeout: 3000,
  errorThresholdPercentage: 50,
  resetTimeout: 30000,
};
const breaker = new circuitBreaker(otaApiCall, options);
```

---

### 2.5 Bảo mật và Toàn vẹn Dữ liệu

#### 2.5.1 Smartlock Code Encryption

```typescript
// Mã hóa AES-256-GCM (authenticated encryption)
const crypto = require('crypto');

function encryptCode(plainCode, key) {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  const encrypted = Buffer.concat([cipher.update(plainCode), cipher.final()]);
  const tag = cipher.getAuthTag();
  return { iv: iv.toString('hex'), encrypted: encrypted.toString('hex'), tag: tag.toString('hex') };
}

function decryptCode(encryptedData, key) {
  const decipher = crypto.createDecipheriv(
    'aes-256-gcm',
    key,
    Buffer.from(encryptedData.iv, 'hex')
  );
  decipher.setAuthTag(Buffer.from(encryptedData.tag, 'hex'));
  return decipher.update(encryptedData.encrypted, 'hex') + decipher.final('utf8');
}
```

**Nguyên tắc bảo mật:**
- `code_plaintext` **không bao giờ** được lưu trong database — chỉ lưu `code_encrypted`
- Booking Service giữ khóa giải mã (hoặc dùng KMS như AWS KMS, HashiCorp Vault)
- **Chỉ App (client-side)** giải mã để hiển thị cho guest — ngay cả DB admin cũng không đọc được mã
- `code_expires_at` được set = `checkout_time + buffer_minutes` — mã tự động hết hạn sau thời điểm checkout + buffer

#### 2.5.2 Channel Manager Authentication

OTA / Channel Manager API thường dùng:
- **API Key + Secret** (SiteMinder): gửi `X-API-Key` header
- **OAuth 2.0 Client Credentials** (Channex): dùng access token JWT
- **Signature-based auth**: ký request bằng HMAC-SHA256

Tất cả credentials phải lưu trong **Secrets Manager** (AWS Secrets Manager / HashiCorp Vault), KHÔNG trong env vars hoặc code.

---

## 3. Khuyến nghị Công nghệ cho NestJS

### 3.1 Core Framework & Runtime

| Công nghệ | Phiên bản | Ghi chú |
|-----------|-----------|---------|
| **NestJS** | 10+ | Microservice support native, Fastify adapter, decorator performance tốt hơn |
| **TypeScript** | 5.3+ | `import_attributes` cho JSON modules, type inference cải thiện |
| **Node.js** | 20 LTS | Native fetch API, V8 cải thiện, memory management cho high-concurrency |
| **Zod** | cho runtime validation | **BẮT BUỘC** thay vì chỉ dùng `class-validator`. Zod cung cấp **runtime type safety** — phát hiện lỗi type khi thực sự chạy, đặc biệt quan trọng cho config và API payload từ OTA. |

---

### 3.2 Database & ORM

| Công nghệ | Vai trò | Ghi chú |
|-----------|---------|---------|
| **Prisma ORM** | ORM chính | Type-safe queries, migration management, generated client. Prisma transaction API sạch hơn cho 2-transaction booking pattern. **Performance ngang raw driver** cho hầu hết workload. |
| **Prisma + `$queryRaw`** | Hybrid | Dùng Prisma cho CRUD thông thường. Dùng `$queryRaw` cho atomic inventory UPDATE với pessimistic locking. |
| **PostgreSQL** | Database | Hỗ trợ: partitioning, RLS, advisory locks, JSONB, `gen_random_uuid()`, full-text search. |
| **pg_partman** | Partition management | Extension tự động tạo và drop partition theo schedule. Giảm overhead vận hành. |
| **ioredis** | Redis client | Cluster mode cho HA, Pub/Sub cho real-time notification. |

---

### 3.3 Message Broker & Event-Driven

| Công nghệ | Vai trò | Ghi chú |
|-----------|---------|---------|
| **Kafka (Confluent)** | Message broker chính | Được khuyến nghị cho Homi 1.0 vì: (1) **event sourcing** capability, (2) **replay** — consumer mới có thể đọc lại toàn bộ lịch sử, (3) **throughput cực cao** phù hợp 100k orders, (4) **consumer groups** — nhiều service cùng consume một topic. |
| **KafkaJS** | Kafka client cho Node | Nhẹ, Promises-based, hỗ trợ Avro/JSON schema registry. |
| **RabbitMQ** | Thay thế nếu Kafka quá phức tạp | Dead-letter exchange (DLX) cho retry, TTL cho message expiration. |

---

### 3.4 Job Queue & Background Processing

| Công nghệ | Vai trò | Ghi chú |
|-----------|---------|---------|
| **BullMQ** | Job queue | Redis-backed, retry với exponential backoff, priority queues, delayed jobs. Dùng cho: (1) pending booking expiration, (2) OTA iCal sync, (3) outbox relay, (4) idempotency cleanup. |
| **@nestjs/schedule** | Simple cron | Cho internal cron đơn giản (VD: cleanup expired idempotency keys). BullMQ cho job nào touch external system. |

---

### 3.5 Caching Strategy

| Chiến lược | TTL | Invalidation |
|-----------|-----|-------------|
| **Cache-Aside** (Room availability) | 30s | Invalidate on write (booking/cancellation). Redis `DEL` key khi `room_availability.updated_at` thay đổi. |
| **Read-through** (Property/Room config) | 5 phút | Dùng cho `rooms`, `room_types` — dữ liệu ít thay đổi. |
| **Write-through** (Pricing rules) | 1 phút | Cache kết quả pricing engine. |

```typescript
// Cache-Aside pattern implementation
async getAvailability(roomId: string, date: string) {
  const cacheKey = `availability:${roomId}:${date}`;
  const cached = await this.redis.get(cacheKey);
  if (cached) return JSON.parse(cached);

  const result = await this.prisma.roomAvailability.findMany({ /* query */ });
  await this.redis.setex(cacheKey, 30, JSON.stringify(result));
  return result;
}
```

---

### 3.6 Observability & Monitoring

| Công nghệ | Vai trò | Metric quan trọng |
|-----------|---------|------------------|
| **Winston + Morgan** | Structured logging | Correlation ID (trace mọi booking từ API → Redis → DB → OTA). Output JSON cho log aggregation (ELK stack / Loki). |
| **Prometheus** | Metrics collection | `booking_request_duration_seconds`, `room_availability_current_units`, `redis_lock_contention_total`, `ota_sync_success_rate`, `concurrent_bookings_in_progress`. |
| **Grafana** | Visualization & Alerting | Dashboard theo dõi: latency p99, error rate, throughput, lock contention. Alert khi `booked_units + on_hold_units > total_units` (overbooking signal). |
| **OpenTelemetry** | Distributed tracing | Trace ID flow từ Client → API Gateway → Room Service → DB → Booking Service → OTA. Quan trọng để debug latency trong 2-transaction flow. |
| **Sentry** | Error tracking | Context: correlation ID, user ID, room ID, booking ID. Alert on booking failures. |
| **@nestjs/terminus** | Health check | Endpoint `/health`: DB connectivity, Redis connectivity, Smartlock API availability. Dùng cho load balancer probe. |

---

### 3.7 Security

| Công nghệ | Vai trò |
|-----------|---------|
| **@nestjs/passport + JWT** | Authentication cho Host/Admin endpoints. Smartlock code decryption yêu cầu JWT hợp lệ với `role: guest` hoặc `role: host`. |
| **@nestjs/throttler** | Rate limiting — BẮT BUỘC trên endpoint booking. Flash-sale protection: limit 2 booking attempts/user/10s. |
| **Helmet** | HTTP security headers (XSS, clickjacking, MIME sniffing). |
| **HashiCorp Vault / AWS Secrets Manager** | Lưu Smartlock API keys, OTA credentials, DB passwords. KHÔNG trong env vars. |
| **class-validator + Zod** | Input sanitization. JSONB fields (`property_data`) cần validate chặt chẽ để tránh NoSQL injection. |

---

### 3.8 Testing

| Công nghệ | Vai trò |
|-----------|---------|
| **Jest** | Unit test. Đặc biệt viết unit test cho: (1) atomic inventory update logic, (2) pricing engine calculation, (3) slot generation cho HOURLY mode. |
| **Testcontainers** | Integration test với PostgreSQL + Redis thực sự trong Docker. **BẮT BUỘC** để test pessimistic locking behavior mà không mock. |
| **Supertest** | API integration test — test booking endpoint end-to-end bao gồm cả Redis lock acquisition. |
| **k6** | Load test — mô phỏng 100k concurrent orders. Verify: (1) không overbooking, (2) lock contention không gây timeout, (3) PENDING_PAYMENT expiration hoạt động đúng. |

---

### 3.9 Project Structure (NestJS)

```
src/
├── main.ts
├── app.module.ts
├── common/
│   ├── decorators/
│   │   ├── idempotency-key.decorator.ts
│   │   └── current-user.decorator.ts
│   ├── filters/
│   │   └── http-exception.filter.ts
│   ├── interceptors/
│   │   ├── logging.interceptor.ts
│   │   └── tracing.interceptor.ts
│   ├── guards/
│   │   ├── jwt-auth.guard.ts
│   │   ├── roles.guard.ts
│   │   └── throttler.guard.ts
│   └── pipes/
│       └── validation.pipe.ts
├── config/
│   └── configuration.ts          # Zod schema validation cho env vars
├── database/
│   ├── prisma.service.ts          # Singleton Prisma client
│   └── prisma.module.ts
├── messaging/
│   ├── kafka.service.ts           # KafkaJS producer/consumer wrapper
│   └── outbox-relay.service.ts    # Poll room_booking_events, publish to broker
├── modules/
│   ├── properties/
│   │   ├── properties.module.ts
│   │   ├── properties.controller.ts
│   │   ├── properties.service.ts
│   │   └── dto/
│   ├── rooms/
│   │   ├── rooms.module.ts
│   │   ├── rooms.controller.ts
│   │   └── rooms.service.ts
│   ├── availability/
│   │   ├── availability.module.ts
│   │   ├── availability.controller.ts
│   │   ├── availability.service.ts
│   │   ├── inventory-atomic.service.ts  # Atomic UPDATE logic
│   │   └── slot-generator.service.ts    # HOURLY slot generation
│   ├── bookings/
│   │   ├── bookings.module.ts
│   │   ├── bookings.controller.ts
│   │   ├── bookings.service.ts          # 2-transaction flow
│   │   └── idempotency.service.ts
│   ├── smartlock/
│   │   ├── smartlock.module.ts
│   │   ├── smartlock.service.ts
│   │   └── encryption.service.ts        # AES-256-GCM
│   ├── ota-sync/
│   │   ├── ota-sync.module.ts
│   │   ├── ical-sync.service.ts
│   │   ├── channel-manager.service.ts
│   │   └── inventory-sync-log.service.ts
│   └── admin/
│       ├── admin.module.ts
│       ├── admin.controller.ts
│       └── create-room-request.service.ts
├── queues/
│   ├── queue.module.ts
│   ├── pending-booking.processor.ts    # BullMQ: expired PENDING cleanup
│   ├── ota-notification.processor.ts  # BullMQ: outbox relay
│   └── idempotency-cleanup.processor.ts
└── health/
    ├── health.module.ts
    └── health.controller.ts
```

---

### 3.10 Deployment & DevOps

| Công nghệ | Vai trò |
|-----------|---------|
| **Docker + Docker Compose** | Dev environment parity, reproducible builds |
| **GitHub Actions** | CI: test, Prisma migrate, build. CD: push image to registry, deploy to Kubernetes |
| **Kubernetes (EKS/GKE)** | Production: stateless deployment, HPA (Horizontal Pod Autoscaler) scale theo custom Prometheus metrics (concurrent booking requests) |
| **Prisma Migrate** | Version-controlled migrations. **KHÔNG BAO GIỜ** sửa migration file sau khi đã apply lên production |
| **pgBackRest** | PostgreSQL backup — Point-in-time recovery (PITR) cho database. Backup mỗi 15 phút, retention 30 ngày |
| **ArgoCD / Flux** | GitOps deployment — sync Kubernetes manifests từ Git repo |

---

## 4. Đảm Bảo Toàn Vẹn Dữ Liệu (Data Integrity)

### 4.1 Mô Hình Nhiều Tầng Bảo Vệ

```
Tầng 1: API Layer         → Validation DTO, Idempotency Key, Rate Limiting
Tầng 2: Database Layer   → CHECK Constraints, FK, NOT NULL, UNIQUE, Partial Index
Tầng 3: Concurrency      → Redis SETNX, SELECT FOR UPDATE, Advisory Locks, Optimistic Lock
Tầng 4: Business Logic   → Atomic UPDATE Formula, State Transition Guard, buffer_minutes
Tầng 5: Event Layer      → Outbox Pattern, Consumer Idempotency, DLQ + Retry
Tầng 6: Audit Trail      → updated_at, deleted_at, AUDIT_LOGS
```

---

### 4.1 Trạng thái Phòng — Vòng đời 7 Trạng thái

Hệ thống Homi 1.0 định nghĩa **7 trạng thái phòng**, mỗi trạng thái có ý nghĩa nghiệp vụ riêng biệt và chuyển đổi theo quy tắc nghiêm ngặt.

#### 4.1.1 Bảng mô tả 7 trạng thái

| Trạng thái | Mã | Mô tả kỹ thuật | Visible với guest |
|------------|-----|----------------|--------------------|
| **Sẵn sàng** | `AVAILABLE` | Phòng trống, sạch sẽ, có thể đặt ngay | ✅ Yes |
| **Chờ thanh toán** | `PENDING` | Đã giữ chỗ (PENDING_PAYMENT) chờ thanh toán VietQR | ❌ No |
| **Đã đặt** | `BOOKED` | Đã thanh toán thành công, chưa check-in | ❌ No |
| **Đang ở** | `OCCUPIED` | Guest đã check-in, đang sử dụng phòng | ❌ No |
| **Đang dọn dẹp** | `CLEANING` | Guest checkout xong, chờ housekeeping hoàn tất | ❌ No |
| **Đóng cửa** | `CLOSED` | Admin đóng phòng thủ công (nghỉ phép, sửa chữa...) | ❌ No |
| **Bảo trì** | `MAINTENANCE` | Phát hiện hư hỏng cần sửa chữa | ❌ No |

**Quy tắc quan trọng:** Chỉ trạng thái `AVAILABLE` mới hiển thị cho guest và có thể nhận đặt phòng mới.

#### 4.1.2 Quy tắc chuyển đổi trạng thái (State Transition Rules)

Mỗi chuyển đổi trạng thái phải tuân theo ma trận bên dưới. Các chuyển đổi không được liệt kê = **bị cấm**.

```
AVAILABLE  → PENDING    : Guest nhấn "Thanh toán" (booking submitted)
AVAILABLE  → CLOSED     : Admin đóng phòng thủ công
AVAILABLE  → MAINTENANCE: Phát hiện vấn đề kỹ thuật
AVAILABLE  → [*]        : Xóa phòng (soft delete)

PENDING    → AVAILABLE  : Thanh toán thất bại / timeout (10 phút)
PENDING    → BOOKED     : Thanh toán thành công
PENDING    → AVAILABLE  : Retry idempotency detected

BOOKED     → OCCUPIED   : Guest nhấn "Check-in"
BOOKED     → CANCELLED   : Guest hủy trước check-in
BOOKED     → AVAILABLE  : Booking expired (không check-in sau 24h)
BOOKED     → CLEANING   : Admin/hệ thống hủy sau khi guest đã ở

OCCUPIED   → CLEANING   : Guest nhấn "Check-out"
OCCUPIED   → CANCELLED   : Khẩn cấp (emergency)

CLEANING   → AVAILABLE  : Housekeeping hoàn tất
CLEANING   → MAINTENANCE: Phát hiện hư hỏng khi dọn phòng

CLOSED     → AVAILABLE  : Admin mở lại phòng
CLOSED     → MAINTENANCE: Phát hiện vấn đề khi đóng
CLOSED     → [*]        : Xóa phòng

MAINTENANCE→ AVAILABLE  : Sửa chữa hoàn tất
MAINTENANCE→ CLEANING   : Sửa nhanh xong, chỉ cần dọn dẹp
```

#### 4.1.3 Mô hình DAILY — Check-out Timeline

Với thuê theo ngày, mỗi ngày chỉ có **một booking**. Chu kỳ đơn giản:

```
14:00 Check-in ──[OCCUPIED]── 12:00 Check-out ──[CLEANING 90m]── 13:30 Available
```

**Công thức tính available time (DAILY):**
```
available_time = checkout_time + buffer_minutes
```

**Ví dụ:**
- Checkout: 12:00
- buffer_minutes: 90 (1 tiếng rưỡi)
- Available: 13:30

#### 4.1.4 Mô hình HOURLY — Check-out Timeline (Phức tạp)

Với thuê theo giờ, **một ngày có thể có nhiều booking**. Mỗi checkout tạo ra một buffer riêng, và các buffer có thể **chồng lấn**.

**Ví dụ một ngày phức tạp:**

```
08:00-12:00  Booking A ──[CLEANING 30m]── 12:30 ── Booking B ──[CLEANING 30m]── 17:00 ── Booking C ──[CLEANING 30m]── 20:30
                                                        ↑
                                                    Walk-in
                                                    16:30-20:00
```

**Công thức tính available time (HOURLY):**
```
available_time = last_checkout_time + buffer_minutes
```

**Thuật toán tính tất cả khe giờ trống trong ngày:**

```typescript
function calculateHourlySlots(
  roomId: string,
  date: string,
  checkouts: CheckoutEvent[],
  bufferMinutes: number
): HourlySlot[] {
  const slots: HourlySlot[] = [];

  // Sắp xếp checkout theo thời gian
  const sorted = checkouts.sort((a, b) =>
    a.checkoutTime.localeCompare(b.checkoutTime));

  // Slot 00:00 - first_checkout - buffer
  const dayStart = `${date} 00:00:00`;
  const firstAvailable = subtractMinutes(
    sorted[0].checkoutTime, bufferMinutes);

  if (firstAvailable > dayStart) {
    slots.push({ start: dayStart, end: firstAvailable, status: 'AVAILABLE' });
  }

  // Tạo slot cho mỗi booking
  sorted.forEach((checkout, i) => {
    const bufferEnd = addMinutes(checkout.checkoutTime, bufferMinutes);

    // Slot OCCUPIED
    slots.push({
      start: checkout.checkinTime,
      end: checkout.checkoutTime,
      status: 'OCCUPIED',
      bookingId: checkout.bookingId,
    });

    // Slot CLEANING
    slots.push({
      start: checkout.checkoutTime,
      end: bufferEnd,
      status: 'CLEANING',
      bookingId: checkout.bookingId,
    });

    // Slot AVAILABLE tiếp theo
    const nextCheckout = sorted[i + 1]?.checkoutTime;
    if (nextCheckout) {
      const nextAvailable = subtractMinutes(nextCheckout, bufferMinutes);
      if (bufferEnd < nextAvailable) {
        slots.push({ start: bufferEnd, end: nextAvailable, status: 'AVAILABLE' });
      }
    } else {
      // Sau booking cuối → available đến 23:59
      slots.push({ start: bufferEnd, end: `${date} 23:59:59`, status: 'AVAILABLE' });
    }
  });

  return slots;
}
```

#### 4.1.5 So sánh DAILY vs HOURLY

| Khía cạnh | DAILY | HOURLY |
|-----------|-------|--------|
| Số booking/ngày | 1 (hoặc 0) | Nhiều (1-24) |
| Buffer tính toán | 1 lần/ngày | N lần (mỗi checkout) |
| Partition key | `DATE` là đủ | Cần `(DATE, START_TIME)` |
| Slot generation | Tự động khi tạo booking | Cron mỗi 15 phút hoặc event-driven |
| Overlap check | 1 row/ngày, đơn giản | Nhiều row, cần kiểm tra từng khe |
| Walk-in support | Không phổ biến | **Rất phổ biến** — slot trống giữa bookings |
| Overnight booking | Không áp dụng | Cần tạo slots cho 2 ngày liền kề |

#### 4.1.6 State Transition Guard — Bảo vệ Admin Status Change

Khi Admin/Host thay đổi trạng thái phòng (VD: CLOSED), hệ thống phải kiểm tra **không có booking đang active**:

```sql
-- CHECK trước khi cho phép đóng phòng
CREATE OR REPLACE FUNCTION fn_check_before_status_change()
RETURNS TRIGGER AS $$
DECLARE
  active_bookings INT;
BEGIN
  IF NEW.status = 'CLOSED' AND OLD.status != 'CLOSED' THEN
    SELECT COUNT(*) INTO active_bookings
    FROM slot_bookings sb
    JOIN room_availability ra ON ra.id = sb.availability_slot_id
    WHERE ra.room_id = NEW.room_id
      AND ra.date = NEW.date
      AND sb.status IN ('PENDING_PAYMENT', 'CONFIRMED', 'CHECKED_IN');

    IF active_bookings > 0 THEN
      RAISE EXCEPTION 'Cannot close room: % active bookings exist', active_bookings;
    END IF;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_room_status_guard
BEFORE UPDATE ON room_availability
FOR EACH ROW EXECUTE FUNCTION fn_check_before_status_change();
```

#### 4.1.7 Cron Job — Tự động chuyển CLEANING → AVAILABLE

Vì `buffer_minutes` có thể kết thúc vào lúc **bất kỳ thời điểm nào** (không trùng với cron), cần chạy cron **mỗi 5 phút** để phát hiện các slot đã hết buffer:

```typescript
// Cron: every 5 minutes
@Cron(CronExpression.EVERY_5_MINUTES)
async releaseExpiredCleaningSlots() {
  const now = new Date();

  // Tìm tất cả slot đang CLEANING mà buffer đã hết
  const expiredSlots = await this.prisma.$queryRaw<RoomAvailability[]>`
    SELECT ra.* FROM room_availability ra
    JOIN slot_bookings sb ON sb.availability_slot_id = ra.id
    WHERE ra.status = 'CLEANING'
      AND sb.checkout_time + (ra.buffer_minutes || ' minutes')::interval < ${now}
  `;

  for (const slot of expiredSlots) {
    await this.prisma.$transaction(async (tx) => {
      // Chuyển CLEANING → AVAILABLE
      await tx.roomAvailability.update({
        where: { id: slot.id },
        data: {
          status: 'AVAILABLE',
          updatedAt: now,
        },
      });

      // Gửi event cho OTA sync
      await tx.roomBookingEvents.create({
        data: {
          eventType: 'CLEANING_COMPLETED',
          roomId: slot.roomId,
          slotId: slot.id,
          payload: { previousStatus: 'CLEANING', newStatus: 'AVAILABLE' },
          status: 'PENDING',
        },
      });
    });

    // Invalidate cache + push OTA
    await this.cacheService.del(`availability:${slot.roomId}:${slot.date}`);
    await this.otaSyncService.pushSlotUpdate(slot);
  }
}
```

#### 4.1.8 5 Edge Cases đặc biệt của HOURLY

**1. Back-to-Back Booking (đặt liền):**
- Guest A checkout 12:00. Guest B đã đặt từ 12:00.
- Logic: `checkout + buffer <= next_booking_start` → không cần buffer, chuyển OCCUPIED ngay cho B.

**2. Walk-in trong thời gian CLEANING:**
- Phòng đang CLEANING 12:00-12:30. Walk-in đến 12:15 muốn đặt 12:30.
- Logic: Nếu `now >= 12:00` → cho phép walk-in từ thời điểm hiện tại. Không cần đợi hết 30 phút buffer.

**3. Overlapping Booking (đặt trùng giờ):**
- Đã có booking 10:00-14:00. Guest mới đặt 12:00-16:00.
- Logic: Kiểm tra tất cả slots trong khoảng 12:00-16:00. Phát hiện overlap → reject.

**4. Extend Stay (kéo dài thời gian):**
- Guest đặt 10:00-12:00, muốn kéo dài đến 14:00.
- Logic: Kiểm tra slots 12:00-14:00. Nếu slot 13:00 bị booking khác giữ → chỉ offer đến 13:00.

**5. Overnight HOURLY (qua đêm):**
- Guest đặt 22:00 ngày 1 đến 06:00 ngày 2.
- Logic: Tạo 2 partition rows — một cho ngày 1 (22:00-24:00), một cho ngày 2 (00:00-06:00). Tổng giá = sum của cả 2 slot.

---

### 4.2 Atomic UPDATE — Công Thức Chống Overbooking

Đây là cơ chế ** quan trọng nhất** của hệ thống. Câu lệnh SQL đảm bảo không bao giờ xảy ra overbooking ngay cả khi 100k request đồng thời.

```sql
-- CÂU LỆNH NGUYÊN TỬ — chỉ tăng on_hold_units khi còn phòng trống
UPDATE room_availability
SET
    on_hold_units = on_hold_units + 1,
    version = version + 1,
    updated_at = now()
WHERE id = :slot_id
  AND status = 'OPEN'
  AND (total_units + overbooking_buffer - booked_units - on_hold_units) > 0;

-- Nếu rows_affected = 0 → không còn phòng trống hoặc slot bị khóa
-- Nếu rows_affected = 1 → hold thành công
```

**Tại sao phải là một câu UPDATE duy nhất?**
- PostgreSQL thực thi atomic — không có race condition giữa CHECK và UPDATE
- `WHERE` clause là một phần của UPDATE — không có khoảng trống giữa kiểm tra và ghi
- `version = version + 1` đảm bảo optimistic locking là lớp bảo vệ thứ hai

---

### 4.3 CHECK Constraints — Ràng Buộc Cấp Database

```sql
-- Ngăn giá trị âm trong inventory
ALTER TABLE room_availability ADD CONSTRAINT chk_non_negative_units
    CHECK (
        booked_units >= 0
        AND on_hold_units >= 0
        AND total_units > 0
        AND booked_units + on_hold_units <= total_units + overbooking_buffer
    );

-- Ngăn cấu hình phòng không hợp lệ
ALTER TABLE rooms ADD CONSTRAINT chk_rental_config
    CHECK (
        rental_type IN ('DAILY', 'HOURLY', 'BOTH')
        AND min_hours >= 1
        AND max_hours IS NULL OR max_hours >= min_hours
        AND (hourly_price IS NULL OR hourly_price > 0)
        AND base_price > 0
    );

-- Ngăn ngày trong quá khứ cho availability
ALTER TABLE room_availability ADD CONSTRAINT chk_future_date
    CHECK (date >= CURRENT_DATE);

-- Ngăn booking với số khách vượt quá sức chứa
ALTER TABLE room_slot_bookings ADD CONSTRAINT chk_guest_count
    CHECK (guest_count <= (SELECT max_guests FROM rooms r JOIN room_availability ra ON ra.room_id = r.id WHERE ra.id = availability_id));
```

---

### 4.4 Optimistic Locking — Phát Hiện Concurrent Modification

```sql
-- Thêm trường version vào room_availability
ALTER TABLE room_availability ADD COLUMN version INT DEFAULT 1;

-- Khi client đọc dữ liệu → client biết version hiện tại
SELECT * FROM room_availability WHERE id = :id;
-- → { ..., version: 5, ... }

-- Khi client ghi → kiểm tra version chưa đổi
UPDATE room_availability
SET status = 'CLOSED', version = version + 1
WHERE id = :id AND version = 5;
-- rows_affected = 1 → thành công
-- rows_affected = 0 → có người khác đã sửa → trả 409 Conflict
```

**Tại sao cần cả pessimistic AND optimistic locking?**

| Tình huống | Pessimistic (SELECT FOR UPDATE) | Optimistic (version) |
|-----------|----------------------------------|----------------------|
| Giữ slot đặt phòng | **BẮT BUỘC** — ngăn race condition | Thêm vào để phát hiện concurrent update |
| Cập nhật thông tin phòng | Không cần — đọc rồi ghi | **BẮT BUỘC** — nhiều admin có thể edit cùng lúc |
| Multi-room booking | **Advisory lock** cho nhiều row | Không đủ cho multi-row |

---

### 4.5 Transactional Outbox — Đảm Bảo Event Không Bị Mất

**Vấn đề:** Khi booking được confirm, Room Service cần (1) cập nhật DB VÀ (2) gửi event đến Kafka. Nếu Kafka fail sau khi DB commit → hệ thống inconsistent.

**Giải pháp:** Ghi event vào bảng `room_booking_events` TRONG CÙNG transaction với data change. Relay process riêng biệt đọc và publish.

```sql
BEGIN TRANSACTION;
    -- 1. Cập nhật availability
    UPDATE room_availability
    SET booked_units = booked_units + 1,
        on_hold_units = on_hold_units - 1,
        version = version + 1,
        updated_at = now()
    WHERE id = :slot_id;

    -- 2. Cập nhật slot_booking
    UPDATE room_slot_bookings
    SET status = 'CONFIRMED', check_in_at = :check_in
    WHERE availability_id = :slot_id AND external_booking_id = :booking_id;

    -- 3. Ghi event VÀO CÙNG transaction
    INSERT INTO room_booking_events
        (aggregate_type, aggregate_id, event_type, payload, status, created_at)
    VALUES
        ('availability', :slot_id, 'ROOM_AVAILABILITY_CONFIRMED',
         '{"booking_id": :booking_id, "room_id": :room_id}',
         'PENDING', now());
COMMIT;
-- Transaction thành công: cả data change và event ghi cùng lúc hoặc cùng rollback
```

**Outbox Relay Process (BullMQ worker):**
```typescript
@Processor('outbox-relay')
async processOutbox() {
  const events = await this.prisma.roomBookingEvents.findMany({
    where: { status: 'PENDING', retry_count: { lt: 5 } },
    orderBy: { created_at: 'asc' },
    take: 100,
  });

  for (const event of events) {
    try {
      await this.kafkaProducer.send({ topic: event.event_type, messages: [event.payload] });
      await this.prisma.roomBookingEvents.update({
        where: { id: event.id },
        data: { status: 'PUBLISHED', published_at: new Date() },
      });
    } catch (error) {
      await this.prisma.roomBookingEvents.update({
        where: { id: event.id },
        data: { status: 'FAILED', retry_count: { increment: 1 } },
      });
      // Alert Admin khi retry_count >= 5
    }
  }
}
```

---

### 4.6 Consumer Idempotency — Xử Lý Event Trùng Lặp

Kafka/RabbitMQ có thể deliver event nhiều lần (at-least-once delivery). Consumer phải xử lý idempotent.

```sql
-- Bảng lưu event đã xử lý
CREATE TABLE event_idempotency (
    event_id UUID PRIMARY KEY,
    processed_at TIMESTAMPTZ DEFAULT now(),
    result JSONB
);

-- TTL: tự động xóa sau 7 ngày
CREATE INDEX idx_event_idempotency_ttl
    ON event_idempotency (processed_at)
    WHERE processed_at < now() - INTERVAL '7 days';
```

```typescript
async handleBookingConfirmed(event: BookingConfirmedEvent) {
  // 1. Check đã xử lý chưa
  const existing = await this.prisma.eventIdempotency.findUnique({
    where: { event_id: event.id },
  });
  if (existing) return; // skip duplicate

  // 2. Xử lý business logic
  await this.prisma.$transaction([
    this.prisma.roomSlotBookings.update({ ... }),
    this.prisma.roomAvailability.update({ ... }),
  ]);

  // 3. Mark là đã xử lý
  await this.prisma.eventIdempotency.create({
    data: { event_id: event.id, result: { status: 'processed' } },
  });
}
```

---

### 4.7 Soft Delete — Bảo Vệ Dữ Liệu Khỏi Xóa Nhầm

Tất cả các bảng chính đều có trường `deleted_at`:

```sql
-- Mặc định, tất cả query phải filter deleted_at
-- Best practice: tạo view hoặc Prisma middleware
CREATE VIEW v_rooms_active AS
    SELECT * FROM rooms WHERE deleted_at IS NULL;

-- Trigger tự động set deleted_at khi DELETE
CREATE OR REPLACE FUNCTION soft_delete()
RETURNS TRIGGER AS $$
BEGIN
    OLD.deleted_at = now();
    UPDATE room_availability SET deleted_at = now() WHERE room_id = OLD.id;
    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_room_soft_delete
    BEFORE DELETE ON rooms
    FOR EACH ROW EXECUTE FUNCTION soft_delete();
```

**Các bảng cần soft delete:**
- `properties` — xóa property không mất lịch sử
- `rooms` — xóa phòng không orphan các booking đã xác nhận
- `room_media` — xóa ảnh không mất reference
- `bookings` — xóa booking không mất audit trail
- `smartlock_codes` — xóa không mất lịch sử truy cập

---

### 4.8 Audit Trail — Ghi Nhận Mọi Thay Đổi

Bảng `AUDIT_LOGS` ghi lại **mọi thay đổi** trên các bảng nhạy cảm:

```sql
CREATE TABLE audit_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_type VARCHAR(50) NOT NULL,   -- properties, rooms, room_availability
    entity_id UUID NOT NULL,
    action VARCHAR(20) NOT NULL,         -- CREATE, UPDATE, DELETE, STATUS_CHANGE
    old_values JSONB,
    new_values JSONB,
    performed_by UUID,                    -- user_id hoặc system_id
    performed_by_type VARCHAR(20),         -- HOST, ADMIN, SYSTEM
    ip_address INET,
    user_agent TEXT,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- GIN index cho query audit trail
CREATE INDEX idx_audit_logs_entity
    ON audit_logs (entity_type, entity_id, created_at DESC);

-- Trigger tự động ghi audit log
CREATE OR REPLACE FUNCTION audit_trigger()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO audit_logs (entity_type, entity_id, action, old_values, new_values, performed_by, performed_by_type)
    VALUES (
        TG_ARGV[0], OLD.id,
        CASE WHEN TG_OP = 'INSERT' THEN 'CREATE'
             WHEN TG_OP = 'DELETE' THEN 'DELETE'
             ELSE 'UPDATE' END,
        CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN to_jsonb(OLD) END,
        CASE WHEN TG_OP IN ('INSERT', 'UPDATE') THEN to_jsonb(NEW) END,
        current_setting('app.current_user_id', true)::UUID,
        current_setting('app.current_user_type', true)
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```

---

### 4.9 Dead Letter Queue — Xử Lý Event Thất Bại

```typescript
// Consumer với retry + DLQ
async handleEvent(event: Event, retryCount = 0) {
  try {
    await this.processEvent(event);
    await this.broker.ack(event);
  } catch (error) {
    if (retryCount < 5) {
      // Exponential backoff: 1s, 2s, 4s, 8s, 16s
      await this.delay(Math.pow(2, retryCount) * 1000);
      await this.handleEvent(event, retryCount + 1);
    } else {
      // Chuyển sang DLQ
      await this.deadLetterQueue.add('failed-events', {
        event,
        error: error.message,
        failedAt: new Date(),
        retryCount,
      });
      await this.alertService.alert(`Event failed after 5 retries: ${event.type}`);
      await this.broker.ack(event); // ACK để không block queue
    }
  }
}
```

**DLQ Topics:**
- `room.availability.reserved.dlq` — booking slot reservation failed
- `booking.confirmed.dlq` — booking confirmation processing failed
- `ota.sync.failed.dlq` — OTA sync event failed

---

### 4.10 Cache Invalidation — Đồng Bộ Giữa Cache và DB

```typescript
// Invalidate cache khi room_availability thay đổi
// Trigger: hàm after UPDATE trên room_availability
async afterAvailabilityUpdate(slotId: string, roomId: string, date: string) {
  // 1. Xóa cache availability
  await this.redis.del(`availability:${roomId}:${date}`);

  // 2. Invalidate cache của property nếu cần
  await this.redis.del(`property:${propertyId}:summary`);

  // 3. Nếu là OTA-linked room → push update đến OTA
  if (room.isOtaLinked) {
    await this.otaSyncService.pushUpdate(roomId, date);
  }
}
```

**Cache invalidation triggers:**
- `room_availability.updated_at` thay đổi → xóa cache availability
- `rooms.updated_at` thay đổi → xóa cache room config
- `properties.updated_at` thay đổi → xóa cache property summary

---

*Generated: 2026-05-21 — Homi 1.0 Room Service Design Report*

