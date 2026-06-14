# Thiết kế bổ sung Room Service — Availability theo giờ, Guard đóng phòng, và Access Delivery

**Ngày:** 2026-06-04  
**Phạm vi:** Room Service / Booking Service / Self Check-in  
**Trạng thái:** Draft đã được thống nhất qua trao đổi

---

## 1. Mục tiêu

Tài liệu này bổ sung 4 nhóm yêu cầu nghiệp vụ còn thiếu trong bộ thiết kế Room Service hiện tại:

1. Cách phòng tự động quay lại trạng thái trống sau `checkout + thời gian dọn dẹp`, đặc biệt trong mô hình `HOURLY`
2. Cơ chế guard khi đổi trạng thái phòng từ `OPEN/AVAILABLE` sang `CLOSED` để ngăn trường hợp khách đã trả tiền nhưng phòng bị đóng
3. Mô hình bảo mật cho thông tin truy cập phòng khi gửi cho khách, bao gồm cả Smartlock và Lockbox / mã do owner cung cấp
4. Mô hình phân tách `rental_type`, `access_mode`, và `self_checkin_enabled` để hỗ trợ đồng thời:
   - thuê theo ngày (`DAILY`)
   - thuê theo giờ (`HOURLY`)
   - owner truyền thống
   - owner tự động hóa

Tài liệu này không thay thế các tài liệu hiện có, mà đóng vai trò đặc tả bổ sung để đồng bộ giữa [AutoCheckinFlow.md](../../../AutoCheckinFlow.md), [RoomAvailable.md](../../../RoomAvailable.md), và [SynchronizedBookingSystem.md](../../../SynchronizedBookingSystem.md).

---

## 2. Mô hình domain bổ sung

### 2.1 Ba trục nghiệp vụ độc lập

Thiết kế bổ sung sử dụng 3 trục riêng biệt và không được gộp chung thành một enum duy nhất.

#### A. `rental_type`
Quyết định logic availability, state transition, và cách tính inventory.

Các giá trị:
- `DAILY`
- `HOURLY`
- `BOTH` chỉ nên được dùng ở tầng cấu hình, không nên là rule thực thi trực tiếp. Khi triển khai inventory, `BOTH` phải được materialize thành slot/rule tương ứng cho từng trường hợp.

#### B. `access_mode`
Quyết định khách sẽ nhận quyền vào phòng bằng cơ chế nào.

Các giá trị đề xuất:
- `MANUAL_HANDOVER` — nhận chìa/thẻ trực tiếp từ lễ tân hoặc Host
- `OWNER_SHARED_CODE` — owner cung cấp mã phòng, mã lockbox, vị trí lấy thẻ từ/chìa khóa; app chỉ hiển thị lại có kiểm soát
- `SMARTLOCK_DEVICE` — hệ thống tích hợp thiết bị, sinh/quản lý mã động, revoke tự động

#### C. `self_checkin_enabled`
Là cờ nghiệp vụ cho biết khách có thể tự nhận phòng qua app mà không cần gặp người bàn giao trực tiếp.

Các giá trị:
- `true`
- `false`

`self_checkin_enabled` không phải là phương thức access. Nó chỉ biểu thị khả năng tự nhận phòng.

---

### 2.2 Mapping theo nhóm owner

#### Owner truyền thống
Có thể dùng:
- `MANUAL_HANDOVER`
- `OWNER_SHARED_CODE`

Không mặc định dùng `SMARTLOCK_DEVICE` nếu không có thiết bị thực.

#### Owner tự động hóa
Ưu tiên dùng:
- `SMARTLOCK_DEVICE`

Có thể có fallback:
- `OWNER_SHARED_CODE`

Điều này cho phép hệ thống xử lý tình huống thiết bị lỗi, pin yếu, provider downtime, hoặc fallback vận hành tạm thời.

---

### 2.3 Quy tắc domain cốt lõi

1. `self_checkin_enabled = true` không bắt buộc phải có `smartlock_device_id`
2. `access_mode = SMARTLOCK_DEVICE` bắt buộc phải có `smartlock_device_id`
3. `access_mode = OWNER_SHARED_CODE` thì app chỉ đóng vai trò phân phối thông tin truy cập, không sinh mã động
4. `rental_type` và `access_mode` là hai trục độc lập, không được gộp chung
5. `DAILY/HOURLY` không quyết định cách giao chìa khóa; chúng chỉ quyết định logic vận hành slot và availability

---

### 2.4 Gợi ý schema

Snippet dưới đây chỉ mang tính minh họa về các cột có thể thêm vào `rooms`; **không phải migration chốt và cũng chưa phải thiết kế schema chính thức**. Migration thực tế sẽ được làm ở bước implementation plan, sau khi chốt enum/table space với team data.

```sql
-- MINH HOA, KHONG PHAI MIGRATION CHOT
ALTER TABLE rooms
ADD COLUMN access_mode access_mode_enum NOT NULL DEFAULT 'MANUAL_HANDOVER',
ADD COLUMN self_checkin_enabled BOOLEAN NOT NULL DEFAULT false,
ADD COLUMN access_visible_lead_minutes SMALLINT NULL;
-- NULL: dung mac dinh theo access_mode (xem muc 5.6)
-- Neu co gia tri: nam trong khoang [0, 1440]
```

Giữ `smartlock_device_id` là nullable.

Với `OWNER_SHARED_CODE`, không dùng `smartlock_device_id`. Thông tin truy cập nên được lưu trong một cấu trúc riêng để có thể quản lý vòng đời, audit, và thời gian hiển thị.

---

## 3. Quy tắc availability sau checkout cho `DAILY` vs `HOURLY`

### 3.1 Mục tiêu

Không dùng một state rule chung cho mọi mô hình. Availability phải phản ánh đúng bản chất vận hành:
- `DAILY`: ưu tiên quy trình sạch, kiểm tra, và bàn giao chắc chắn
- `HOURLY`: ưu tiên tận dụng occupancy, hỗ trợ back-to-back booking mà không tạo khoảng trống giả

---

### 3.2 Rule cho `DAILY`

Luồng chuẩn:

```text
CHECKED_IN -> CHECKED_OUT -> CLEANING -> INSPECTING -> AVAILABLE
```

#### Nguyên tắc
- Sau khi khách checkout, phòng không được quay lại `AVAILABLE` ngay
- Phòng chỉ trở lại `AVAILABLE` khi:
  1. đã checkout xong
  2. đã qua `buffer_minutes`
  3. housekeeping hoàn tất
  4. nếu property yêu cầu, bước `INSPECTING` đã pass

#### Công thức

```text
available_at = actual_checkout_at + cleaning_buffer + inspecting_buffer
```

#### Ý nghĩa nghiệp vụ
- Phù hợp với thuê theo ngày
- Giảm rủi ro bàn giao phòng kém chất lượng
- Dễ hiểu và dễ audit

---

### 3.3 Rule cho `HOURLY`

Khác với `DAILY`, mô hình theo giờ phải hỗ trợ back-to-back booking.

#### Nguyên tắc tổng quát
- Sau `CHECKED_OUT`, phòng chuyển vào turnover window (`CLEANING`, `INSPECTING`, hoặc trạng thái nội bộ tương đương)
- Nếu không có booking kế tiếp hợp lệ, khi turnover hoàn tất thì phòng trở lại `AVAILABLE`
- Nếu đã có booking kế tiếp hợp lệ nối tiếp, phòng không được public `AVAILABLE` ở giữa

Điều này có nghĩa:
- `AVAILABLE` chỉ xuất hiện khi có gap trống thật
- khoảng giữa hai booking nối tiếp chỉ là thời gian turnover nội bộ, không phải inventory công khai

---

### 3.4 Ví dụ chuẩn

#### Ví dụ 1 — Có booking nối tiếp ngay sau buffer
- Booking A checkout lúc `12:00`
- `buffer_minutes = 30`
- Booking B check-in lúc `12:30`

Rule:
- `12:00 -> 12:30`: phòng ở trạng thái turnover nội bộ
- `12:30`: nếu đủ điều kiện, chuyển sang phục vụ booking B
- Không có pha `AVAILABLE` public giữa A và B

#### Ví dụ 2 — Có khoảng trống thật
- Booking A checkout lúc `12:00`
- `buffer_minutes = 30`
- Booking B check-in lúc `13:00`

Rule:
- `12:00 -> 12:30`: turnover nội bộ
- `12:30 -> 13:00`: `AVAILABLE`
- `13:00`: booking B bắt đầu

---

### 3.5 Ba mốc thời gian cần chuẩn hóa

Để tránh mơ hồ, hệ thống nên chuẩn hóa 3 mốc sau:

- `actual_checkout_at` — thời điểm khách thực tế checkout
- `turnover_ready_at` — thời điểm dọn dẹp tối thiểu hoàn tất
- `public_available_at` — thời điểm slot được mở bán công khai trở lại

#### Với `DAILY`
- `public_available_at = turnover_ready_at` hoặc sau `INSPECTING`

#### Với `HOURLY`
- nếu có booking nối tiếp hợp lệ: `public_available_at = null` cho khoảng giữa
- nếu không có booking nối tiếp: `public_available_at = turnover_ready_at`

---

### 3.6 Bất biến quan trọng

> Trong mô hình `HOURLY`, một phòng có thể không có khách bên trong nhưng vẫn không được public `AVAILABLE`, vì nó đang ở turnover window dành cho **booking kế tiếp đã có giữ chỗ hợp lệ** (booking ở trạng thái `CONFIRMED` hoặc `PENDING_PAYMENT` còn nằm trong payment window).

Bất biến này phải được phản ánh nhất quán ở:
- room state
- inventory query
- app search result
- admin UI

**Áp dụng hẹp**: bất biến này chỉ chặn việc public `AVAILABLE` ở khoảng giữa. Nó không có nghĩa là từ chối vô điều kiện mọi khoảng trống. Nếu khoảng trống thật sự không có booking kế tiếp hợp lệ chồng lấn, phòng vẫn có thể quay lại `AVAILABLE` theo rule.

---

## 4. Guard khi đổi trạng thái `OPEN/AVAILABLE -> CLOSED`

### 4.1 Mục tiêu

Ngăn hành động vận hành thủ công phá vỡ quyền đã được giữ hoặc xác lập cho khách.

Không được phép đóng phòng nếu việc đó có thể làm mất quyền sử dụng phòng của:
- một booking đang `PENDING_PAYMENT`
- một slot đang có `on_hold_units > 0`
- một booking đã `CONFIRMED`
- một khách đang `CHECKED_IN`
- một vòng đời turnover chưa kết thúc

---

### 4.2 Hai tầng trạng thái cần guard

#### Tầng A — `rooms.status`
Trạng thái vận hành cấp phòng:
- `AVAILABLE`
- `CLOSED`
- `MAINTENANCE`
- `BLOCKED`

#### Tầng B — `room_availability.status`
Trạng thái inventory theo slot:
- `OPEN`
- `CLOSED`
- `BLOCKED`

Guard phải chạy ở tầng business trước. Chỉ khi pass guard mới được phép cập nhật xuống cả `rooms` và `room_availability`.

---

### 4.3 Blocking states

Các trạng thái sau được xem là đang hoạt động và có khả năng chặn đóng phòng:
- `PENDING_PAYMENT`
- `CONFIRMED`
- `CHECKED_IN`
- `CHECKED_OUT`
- `CLEANING`
- `INSPECTING`

Các trạng thái sau không chặn:
- `CANCELLED`
- `EXPIRED`
- `COMPLETED`
- `REFUNDED` (nếu có)
- các terminal state tương đương

---

### 4.4 Năm guard bắt buộc

#### Guard 1 — Không có `on_hold_units` chồng lấn khoảng thời gian bị đóng
Guard chỉ chặn khi `on_hold_units > 0` ánh xạ đúng slot hoặc khoảng thời gian mà thao tác đóng đang nhắm tới, không phải mọi `on_hold_units` của phòng trong tất cả ngày/slot.

Nếu có `on_hold_units` chồng lấn, nghĩa là inventory đang bị giữ tạm cho giao dịch đang chờ hoàn tất.

Nếu fail:
- từ chối thao tác
- trả lỗi: `ROOM_CLOSE_REJECTED_PENDING_HOLD_EXISTS`

#### Guard 2 — Không có booking `PENDING_PAYMENT` chưa hết hạn
Nếu còn booking đang nằm trong payment window, không cho phép đóng phòng.

#### Guard 3 — Không có booking `CONFIRMED` chồng lấn khoảng thời gian bị đóng
Không chỉ kiểm tra “hôm nay”, mà phải kiểm tra đúng khoảng slot bị ảnh hưởng.

#### Guard 4 — Không có `CHECKED_IN` hoặc turnover đang diễn ra
Nếu khách đang ở hoặc phòng đang trong vòng `CHECKED_OUT -> CLEANING -> INSPECTING`, không cho hard close ngay.

#### Guard 5 — Final check trong transaction/lock
Ngay cả khi pre-check cho kết quả sạch, vẫn có thể xảy ra race condition với payment webhook hoặc booking confirmation. Mọi thao tác `OPEN -> CLOSED` phải chạy final check lần cuối dưới lock/transaction ngắn trước khi commit.

---

### 4.5 Ba mức đóng phòng

#### A. `Immediate close`
Chỉ cho phép khi toàn bộ guard pass.

#### B. `Scheduled close`
Nếu còn booking hoặc hold hợp lệ, hệ thống không đóng ngay mà tạo yêu cầu đóng hiệu lực sau booking cuối cùng + turnover.

Ví dụ thuộc tính:
- `effective_after_last_active_booking`
- hoặc `close_from_datetime`

#### C. `Emergency override`
Không phải flow mặc định. Chỉ Admin/hệ thống đặc quyền mới có thể dùng khi có lý do an toàn, pháp lý, sự cố nghiêm trọng, hoặc bảo trì khẩn cấp.

Khi override phải đi kèm workflow hậu quả:
1. ghi lý do đóng cưỡng bức
2. xác định toàn bộ booking bị ảnh hưởng
3. khóa check-in mới
4. mở quy trình hoàn tiền / đổi phòng / hỗ trợ tranh chấp
5. ghi audit log đầy đủ

---

### 4.6 Khác biệt giữa `DAILY` và `HOURLY`

#### Với `DAILY`
Guard có thể kiểm tra theo khoảng ngày lưu trú.

#### Với `HOURLY`
Guard phải kiểm tra theo khoảng thời gian chồng lấn ở mức `datetime`, không đủ nếu chỉ kiểm tra theo ngày.

Ví dụ:
- host muốn đóng từ `15:00`
- có booking `PENDING_PAYMENT` từ `15:30–17:30`
- có booking `CONFIRMED` từ `18:00–20:00`

=> phải chặn đóng từ `15:00`.

---

### 4.7 Bất biến cần ghi vào tài liệu

> Nếu tồn tại `PENDING_PAYMENT`, `on_hold_units > 0`, `CONFIRMED`, `CHECKED_IN`, hoặc turnover chưa kết thúc trên khoảng thời gian bị ảnh hưởng, hệ thống không được phép chuyển `OPEN/AVAILABLE -> CLOSED` bằng thao tác vận hành thông thường.

> Mọi thao tác `OPEN/AVAILABLE -> CLOSED` phải được xác nhận lại trong final transaction/lock để tránh race với payment webhook hoặc booking confirmation.

---

## 5. Mô hình bảo mật cho Smartlock / Lockbox / mã owner cung cấp

### 5.1 Mục tiêu

Tách rõ hai họ access delivery:

1. `SMARTLOCK_DEVICE` — hệ thống tích hợp thiết bị, tự sinh hoặc nhận mã động, tự revoke
2. `OWNER_SHARED_CODE` — owner cung cấp thông tin truy cập, app chỉ phân phối có kiểm soát

Hai mô hình này không được dùng chung một security assumption.

---

### 5.2 `SMARTLOCK_DEVICE`

Đây là mô hình bảo mật mạnh hơn và có thể tự động hóa trọn vẹn.

#### Quy tắc bảo mật
- `code_plaintext` không được lưu trong database
- `derived_key` không được lưu trữ lâu dài
- `MASTER_ENCRYPTION_KEY` chỉ nằm trong KMS/Vault
- `smartlock_device_id` không lộ trong API client-facing
- mã có `valid_from` và `valid_until`
- mã phải revoke được khi checkout, cancel, hoặc hết hạn

#### Quyền hiển thị
App chỉ hiển thị mã cho đúng guest của booking, trong đúng thời gian hiệu lực.

#### Ghi log
Mọi event mở khóa phải được log để phục vụ audit và dispute.

---

### 5.3 `OWNER_SHARED_CODE`

Đây là mô hình owner truyền thống hoặc bán tự động. App không sinh mã, chỉ phân phối lại thông tin do owner cung cấp.

Ví dụ thông tin có thể được owner nhập:
- mã cửa phòng
- mã lockbox
- vị trí hộp chứa chìa khóa/thẻ từ
- hướng dẫn lấy chìa khóa
- lưu ý check-in đặc biệt

#### Yêu cầu bảo mật
Dù không phải mã động, thông tin này vẫn là secret vận hành và phải được bảo vệ.

Rule đề xuất:
1. không lưu plaintext công khai ở trường mô tả chung của room/property
2. lưu trong bảng/bản ghi chuyên biệt có kiểm soát quyền truy cập
3. mã hóa at rest bằng application-level encryption hoặc KMS-backed envelope encryption
4. chỉ giải mã và trả về cho đúng guest, đúng booking, đúng cửa sổ thời gian
5. mọi lần xem thông tin phải có audit log
6. owner được phép rotate/cập nhật secret mà không sửa lịch sử booking cũ

---

### 5.4 Tách cấu hình access khỏi metadata công khai của phòng

Thông tin truy cập không nên nằm trực tiếp trong các field hiển thị công khai như:
- `room.description`
- `property.note`
- `public_checkin_guide`

Lý do:
- dễ lộ qua API listing
- dễ bị cache hoặc log ngoài ý muốn
- khó phân quyền theo guest/booking

Thay vào đó nên có cấu trúc riêng, ví dụ:

```text
room_access_configs
booking_access_deliveries
```

Trong đó:
- `room_access_configs` lưu cấu hình nguồn
- `booking_access_deliveries` lưu bản phân phối theo booking và theo thời điểm

---

### 5.5 Phân biệt source secret và delivery secret

Đây là điểm quan trọng.

#### Source secret
Là thông tin owner cấu hình ở cấp room/property:
- mã lockbox mặc định
- hướng dẫn lấy chìa
- mã cửa cố định

#### Delivery secret
Là thông tin thực tế được giao cho guest cho một booking cụ thể.

Với `SMARTLOCK_DEVICE`:
- source là device capability
- delivery là mã động theo booking

Với `OWNER_SHARED_CODE`:
- source là thông tin owner nhập
- delivery là snapshot được phát hành cho booking trong cửa sổ hiển thị phù hợp

Tách hai lớp này giúp:
- rotate source secret mà không làm sai audit của booking cũ
- biết chính xác guest nào đã được xem thông tin nào, lúc nào

---

### 5.6 Cửa sổ hiển thị thông tin truy cập

Đề xuất giới hạn cửa sổ hiển thị thông tin truy cập theo booking:
- không hiển thị quá sớm
- tự ẩn hoặc vô hiệu sau checkout/expiry

Hệ thống dùng cơ chế **mặc định theo `access_mode` + owner override trong khoảng `[0, 24 giờ]`**:

1. Cửa sổ mặc định theo `access_mode`:
   - `SMARTLOCK_DEVICE`: `60 phút trước check-in`
   - `OWNER_SHARED_CODE`: `60 phút trước check-in`
   - `MANUAL_HANDOVER`: không phát hành secret

2. Mỗi phòng có thêm trường cấu hình `access_visible_lead_minutes` (nullable, kiểu `SMALLINT`, đơn vị phút):
   - Nếu `null`: dùng mặc định theo `access_mode` ở bước 1
   - Nếu có giá trị: dùng giá trị này, **luôn clamp trong khoảng `[0, 1440]`** (tương đương `[0 phút, 24 giờ]`)

3. Sau khi áp dụng rule trên, cửa sổ hiển thị thực tế là:
   - `visible_from = check_in_at - lead_minutes`
   - `visible_until = checkout_at + buffer_minutes`

4. Giá trị ngoài khoảng `[0, 1440]` do owner nhập phải bị backend từ chối ngay tại API admin, kèm lỗi `ACCESS_LEAD_MINUTES_OUT_OF_RANGE`.

5. Nếu owner cố ý đặt `0` thì secret chỉ hiển thị từ đúng thời điểm check-in, dùng cho case khách hẹn đúng giờ.

Lợi ích của rule này:
- có default chuẩn theo `access_mode` để audit nhất quán
- owner vẫn được tùy chỉnh theo nhu cầu thật
- vẫn bị giới hạn cứng bởi `[0, 24h]` để giảm rủi ro lộ sớm

---

### 5.7 Access mode và self check-in

#### `MANUAL_HANDOVER`
- `self_checkin_enabled = false` là mặc định hợp lý
- app chỉ hiển thị hướng dẫn nhận phòng, liên hệ lễ tân/Host

#### `OWNER_SHARED_CODE`
- `self_checkin_enabled = true` là hợp lệ
- app hiển thị mã/tủ khóa/hướng dẫn owner cung cấp trong cửa sổ cho phép
- không cần `smartlock_device_id`

#### `SMARTLOCK_DEVICE`
- `self_checkin_enabled = true`
- bắt buộc có `smartlock_device_id`
- app hiển thị mã động / BLE / QR / NFC theo khả năng thiết bị

---

### 5.8 Bất biến bảo mật

> Self check-in không đồng nghĩa với Smartlock.

> `OWNER_SHARED_CODE` là mô hình phân phối secret có kiểm soát, không phải text note công khai của phòng.

> `SMARTLOCK_DEVICE` và `OWNER_SHARED_CODE` phải có cơ chế lưu trữ, hiển thị, audit, và rotation riêng.

---

## 6. Tác động lên tài liệu hiện có

### [RoomAvailable.md](../../../RoomAvailable.md)
Cần bổ sung:
- rule `DAILY` vs `HOURLY` cho availability sau checkout
- khái niệm turnover window và `public_available_at`
- bất biến “không public AVAILABLE trong HOURLY nếu đã có booking kế tiếp hợp lệ"

### [SynchronizedBookingSystem.md](../../../SynchronizedBookingSystem.md)
Cần bổ sung:
- guard `OPEN/AVAILABLE -> CLOSED`
- 3 mức đóng phòng: immediate / scheduled / emergency override
- final-check trong transaction/lock để chống race với payment webhook

### [AutoCheckinFlow.md](../../../AutoCheckinFlow.md)
Cần bổ sung:
- `access_mode`
- `self_checkin_enabled`
- tách `SMARTLOCK_DEVICE` và `OWNER_SHARED_CODE`
- security model cho owner-provided access secret

---

## 7. Phạm vi triển khai tiếp theo

Từ spec này, implementation plan tiếp theo nên tách thành các nhóm việc:

1. Cập nhật domain/schema
   - `access_mode`
   - `self_checkin_enabled`
   - bảng/cấu trúc access secret nếu cần

2. Cập nhật state machine và availability engine
   - `DAILY` vs `HOURLY`
   - turnover window
   - `public_available_at`

3. Cập nhật close-room workflow
   - pre-check
   - final transactional check
   - scheduled close
   - emergency override policy

4. Cập nhật access delivery flow
   - smartlock delivery
   - owner shared code delivery
   - visibility window
   - audit logging

---

## 8. Tiêu chí thành công

Thiết kế bổ sung được xem là hoàn chỉnh khi đạt đủ các điều kiện:

1. Hệ thống mô tả rõ cách `HOURLY` quay lại `AVAILABLE` mà không tạo khoảng trống giả giữa hai booking nối tiếp
2. Không thể đóng phòng bằng thao tác thông thường nếu vẫn còn `PENDING_PAYMENT`, `on_hold_units`, `CONFIRMED`, `CHECKED_IN`, hoặc turnover chưa kết thúc
3. Self check-in được mô hình hóa tách biệt khỏi Smartlock
4. Access secret do owner cung cấp được bảo vệ như secret thật sự, không nằm trong mô tả công khai của phòng
5. Tài liệu Room Service, Sync, và Auto Check-in dùng cùng một vocabulary và cùng một bất biến nghiệp vụ
