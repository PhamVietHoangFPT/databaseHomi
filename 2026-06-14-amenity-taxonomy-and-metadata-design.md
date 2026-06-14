# Taxonomy và tiện nghi cho system design.docx

| Scope | Mỗi tiện nghi phải gắn scope: room\_type, property, hoặc building |
| ---| --- |
| Kiểu dữ liệu | Mặc định là boolean; dùng enum khi có nhiều trạng thái; chỉ dùng text khi thật sự cần |
| Phân loại | room, common, unique, service\_building, safety\_legal |
| Tính hiển thị | Có cờ is\_public; dữ liệu private không hiển thị ở listing |
| Tính lọc | Có cờ is\_filterable để dev bật/tắt trên search/filter UI |
| Ưu tiên UI | high, medium, low để quyết định badge nào hiện trên card/listing trước |

## List tiện nghi
List được dựa trên các nền tảng lớn:
*   Airbnb nhấn mạnh pool, kitchen, accessibility features;
*   [Booking.com](http://Booking.com) nhấn mạnh Wi‑Fi quality và pet-friendly;
*   Agoda nhấn mạnh filters, map views, local information và verified review
*   Airbnb cũng tách rõ phần services và check-in instructions. **Tiện nghi phòng**

| Key | Mô tả ngắn | Giá trị điển hình | Ví dụ |
| ---| ---| ---| --- |
| bed\_type | Loại/size giường chính | enum | single, double, queen, king, sofa\_bed |
| private\_bathroom | Có phòng tắm riêng hay không | boolean | true |
| air\_conditioning | Điều hòa hoặc làm mát | boolean hoặc enum | true, hoặc aircon / fan\_only |
| smart\_tv | TV/smart TV trong phòng | boolean | true |
| work\_desk | Bàn làm việc hoặc bàn nhỏ | boolean | true |
| minibar\_fridge | Tủ lạnh nhỏ/minibar | boolean | true |
| kitchenette | Góc bếp hoặc bếp mini | boolean hoặc enum | microwave, kitchenette, full\_kitchen |

**Tiện nghi phổ biến**

| Key | Mô tả | Giá trị điển hình | Ví dụ |
| ---| ---| ---| --- |
| wifi\_available | Có Wi‑Fi hay không | boolean | true |
| wifi\_quality | Chất lượng Wi‑Fi mang tính hiển thị/lọc | enum | basic, good, fast |
| parking | Hình thức gửi xe | enum | none, motorbike\_free, motorbike\_paid, car\_free, car\_paid |
| elevator | Có thang máy | boolean | true |
| breakfast\_option | Có ăn sáng hay không | enum | none, included, paid |
| laundry\_option | Hình thức giặt ủi | enum | none, self\_service, service |
| pet\_friendly | Cho phép ở cùng thú cưng | boolean | true |
| accessibility\_step\_free\_entry | Lối vào không bậc/cản trở | boolean | true |

**Tiện nghi độc đáo**

| Key | Mô tả | Giá trị điển hình | Ví dụ |
| ---| ---| ---| --- |
| bathtub\_or\_jacuzzi | Bồn tắm hoặc jacuzzi | enum | none, bathtub, jacuzzi |
| balcony\_view | Ban công hoặc view nổi bật | enum | none, city, river, garden |
| projector | Máy chiếu hoặc góc xem phim | boolean | true |
| themed\_room | Chủ đề phòng rõ ràng | enum | none, romantic, minimalist, japanese, vintage |
| gaming\_console | Máy chơi game | boolean | true |
| private\_plunge\_pool | Hồ ngâm/hồ nhỏ riêng | enum | none, plunge\_pool, private\_pool |

**Dịch vụ & Tiện ích tòa nhà**

| Key | Mô tả | Giá trị điển hình | Ví dụ |
| ---| ---| ---| --- |
| reception\_24h | Lễ tân 24/7 | boolean | true |
| housekeeping | Dọn phòng | enum | none, on\_request, daily |
| luggage\_storage | Giữ hành lý | boolean | true |
| airport\_pickup | Đưa đón sân bay | boolean | true |
| gym | Phòng gym dùng chung | boolean | true |
| shared\_pool | Hồ bơi dùng chung | boolean | true |
| coworking\_space | Khu làm việc/chờ/chung | boolean | true |

**An toàn & Pháp lý**

| Key | Mô tả ngắn | Giá trị điển hình | Ví dụ | Ưu tiên UI |
| ---| ---| ---| ---| --- |
| smoke\_detector | Có đầu báo khói | boolean | true | High |
| fire\_extinguisher | Có bình chữa cháy | boolean | true | High |
| first\_aid\_kit | Có bộ sơ cứu | boolean | true | Medium |
| self\_check\_in\_method | Cách tự check-in | enum | none, key, lockbox, smartlock, keypad | High |
| cctv\_common\_areas\_disclosed | Có camera khu vực chung và được công khai | boolean | true | Medium |
| id\_required\_at\_checkin | Có yêu cầu giấy tờ/ID lúc check-in | boolean | true | High |
| invoice\_available | Có xuất hóa đơn/chứng từ | boolean | true | Medium |
| emergency\_contact\_available | Có hotline hoặc liên hệ khẩn cấp | boolean | true | High |

## Metadata Requirements cho DB
Airbnb cho biết sau khi đặt chỗ, khách có thể xem check-in time, special instructions, entry codes và cả thông tin để vào Wi‑Fi; vì vậy Homi không nên đưa các dữ liệu như **door code, Wi‑Fi password, house manual private** vào bảng tiện nghi public. Chúng nên nằm trong bảng private hoặc booking-only riêng. Đồng thời, do các OTA dùng bộ lọc và hiển thị có cấu trúc, từng tiện nghi của Homi cần có metadata rõ cho cả dev lẫn UI.
**Metadata của từ điển tiện nghi**

| Field name | Type | Allowed values | Required/Optional | Display label |
| ---| ---| ---| ---| --- |
| amenity\_id | uuid | System generated | Required | ID tiện nghi |
| amenity\_code | text | snake\_case, unique | Required | Mã tiện nghi |
| category\_code | enum | room, common, unique, service\_building, safety\_legal | Required | Nhóm |
| scope | enum | room\_type, property, building | Required | Cấp áp dụng |
| value\_kind | enum | boolean, enum, number, text | Required | Kiểu dữ liệu |
| allowed\_values | jsonb | Mảng giá trị hợp lệ | Optional | Giá trị cho phép |
| display\_label\_vi | text | Chuỗi ngắn tiếng Việt | Required | Nhãn hiển thị |
| short\_desc\_vi | text | 1 câu ngắn | Optional | Mô tả ngắn |
| ui\_priority | enum | high, medium, low | Required | Ưu tiên UI |
| is\_filterable | boolean | true/false | Required | Dùng cho filter |
| is\_public | boolean | true/false | Required | Hiển thị công khai |
| requires\_disclosure | boolean | true/false | Optional | Cần công khai chi tiết |
| icon\_key | text | key map với FE icon set | Optional | Icon |
| sort\_order | smallint | số nguyên dương | Optional | Thứ tự hiển thị |
| external\_mapping | jsonb | map code OTA/channel manager | Optional | Mapping ngoài |

**Metadata của bản ghi giá trị tiện nghi**

| Field name | Type | Allowed values | Required/Optional | Display label |
| ---| ---| ---| ---| --- |
| entity\_type | enum | room\_type, property | Required | Loại thực thể |
| entity\_id | uuid | FK | Required | ID thực thể |
| amenity\_id | uuid | FK | Required | Tiện nghi |
| bool\_value | boolean | true/false | Optional | Giá trị boolean |
| enum\_value | text | nằm trong allowed\_values | Optional | Giá trị enum |
| numeric\_value | numeric | số | Optional | Giá trị số |
| text\_value | text | text có kiểm soát | Optional | Giá trị text |
| visibility | enum | public, private, staff\_only | Required | Mức hiển thị |
| verified\_at | timestamptz | datetime | Optional | Xác minh lúc |
| source\_platform | enum | homi, airbnb, booking, agoda, manual | Optional | Nguồn |
| evidence\_url | text | URL ảnh/chứng cứ nội bộ | Optional | Link minh chứng |

## Schema chuẩn hóa đề xuất

| ![Rendered Mermaid diagram 1](about:blank) |
| --- |

**Bảng chính nên có**

| Table | Vai trò |
| ---| --- |
| properties | Thông tin khách sạn/căn/tòa nhà cấp listing |
| room\_types | Đơn vị bán được theo giờ/ngày |
| amenity\_categories | Danh mục cha |
| amenities | Từ điển mã tiện nghi chuẩn hóa |
| property\_amenities | Tiện nghi/tiện ích cấp tòa nhà hoặc cấp property |
| room\_type\_amenities | Tiện nghi cụ thể của từng loại phòng |
| checkin\_private\_details | Dữ liệu chỉ lộ sau booking, không public |

**Sample rows**
_Bảng amenities_

| amenity\_code | category\_code | scope | value\_kind | display\_label\_vi | ui\_priority | is\_filterable |
| ---| ---| ---| ---| ---| ---| --- |
| wifi\_available | common | property | boolean | Wi‑Fi | high | true |
| wifi\_quality | common | property | enum | Chất lượng Wi‑Fi | high | true |
| self\_check\_in\_method | safety\_legal | room\_type | enum | Tự check-in | high | true |
| bathtub\_or\_jacuzzi | unique | room\_type | enum | Bồn tắm/Jacuzzi | high | true |

_Bảng room\_type\_amenities_

| room\_type\_id | amenity\_code | bool\_value | enum\_value |
| ---| ---| ---| --- |
| rt\_101 | wifi\_available | true | null |
| rt\_101 | wifi\_quality | null | fast |
| rt\_101 | self\_check\_in\_method | null | keypad |
| rt\_209 | bathtub\_or\_jacuzzi | null | jacuzzi |

## Checklist thu thập

| Cần kiểm tra | Câu hỏi ngắn | Kết quả mong muốn |
| ---| ---| --- |
| Xác định scope | Tiện nghi này thuộc phòng hay thuộc tòa nhà? | Chọn đúng room\_type hoặc property |
| Chọn mã chuẩn | Đã có amenity\_code trong dictionary chưa? | Không tạo trùng nghĩa bằng tên khác |
| Chọn đúng kiểu giá trị | Boolean hay enum? | Không nhập text khi enum là đủ |
| Chứng thực | Có ảnh hoặc nguồn nội bộ xác nhận không? | Lưu verified\_at, source\_platform, evidence\_url |
| Hiển thị | Có nên hiện trên card listing không? | Gắn ui\_priority + is\_public |
| Cho filter | Người dùng có thật sự cần lọc theo trường này không? | Gắn is\_filterable=true/false |
| Bảo mật | Đây có phải dữ liệu chỉ lộ sau booking không? | Đưa vào checkin\_private\_details, không public |

**Ví dụ hiển thị trên UI**
_Listing card_
Wi‑Fi mạnh • Máy lạnh • Phòng tắm riêng • Tự check-in • Gửi xe máy
_Trang chi tiết_
Tiện nghi phòng
\- Giường Queen
\- Phòng tắm riêng
\- Smart TV

Tiện nghi phổ biến
\- Wi‑Fi: Fast
\- Thang máy
\- Gửi xe máy miễn phí

Tiện nghi độc đáo
\- Jacuzzi
\- Máy chiếu

Dịch vụ & tòa nhà
\- Lễ tân 24/7
\- Giữ hành lý

An toàn & pháp lý
\- Đầu báo khói
\- Bình chữa cháy
\- Yêu cầu CCCD khi check-in

* * *
Dưới đây là danh sách toàn bộ các tiện nghi được đánh số thứ tự liên tục từ 1 đến 34, phân tách theo từng danh mục để bạn tiện theo dõi:
### 1\. Tiện nghi phòng (Room Amenities)
1. Loại/size giường chính (`bed_type`)
2. Có phòng tắm riêng hay không (`private_bathroom`)
3. Điều hòa hoặc làm mát (`air_conditioning`)
4. TV/smart TV trong phòng (`smart_tv`)
5. Bàn làm việc hoặc bàn nhỏ (`work_desk`)
6. Tủ lạnh nhỏ/minibar (`minibar_fridge`)
7. Góc bếp hoặc bếp mini (`kitchenette`)
### 2\. Tiện nghi phổ biến (Common Amenities)
1. Có Wi‑Fi hay không (`wifi_available`)
2. Chất lượng Wi‑Fi mang tính hiển thị/lọc (`wifi_quality`)
3. Hình thức gửi xe (`parking`)
4. Có thang máy (`elevator`)
5. Có ăn sáng hay không (`breakfast_option`)
6. Hình thức giặt ủi (`laundry_option`)
7. Cho phép ở cùng thú cưng (`pet_friendly`)
8. Lối vào không bậc/cản trở (`accessibility_step_free_entry`)
### 3\. Tiện nghi độc đáo (Unique Amenities)
1. Bồn tắm hoặc jacuzzi (`bathtub_or_jacuzzi`)
2. Ban công hoặc view nổi bật (`balcony_view`)
3. Máy chiếu hoặc góc xem phim (`projector`)
4. Chủ đề phòng rõ ràng (`themed_room`)
5. Máy chơi game (`gaming_console`)
6. Hồ ngâm/hồ nhỏ riêng (`private_plunge_pool`)
### 4\. Dịch vụ & Tiện ích tòa nhà (Building Services & Utilities)
1. Lễ tân 24/7 (`reception_24h`)
2. Dọn phòng (`housekeeping`)
3. Giữ hành lý (`luggage_storage`)
4. Đưa đón sân bay (`airport_pickup`)
5. Phòng gym dùng chung (`gym`)
6. Hồ bơi dùng chung (`shared_pool`)
7. Khu làm việc/chờ/chung (`coworking_space`)
### 5\. An toàn & Pháp lý (Safety & Legal)
1. Có đầu báo khói (`smoke_detector`)
2. Có bình chữa cháy (`fire_extinguisher`)
3. Có bộ sơ cứu (`first_aid_kit`)
4. Cách tự check-in (`self_check_in_method`)
5. Có camera khu vực chung và được công khai (`cctv_common_areas_disclosed`)
6. Có yêu cầu giấy tờ/ID lúc check-in (`id_required_at_checkin`)
7. Có xuất hóa đơn/chứng từ (`invoice_available`)
8. Có hotline hoặc liên hệ khẩn cấp (`emergency_contact_available`)