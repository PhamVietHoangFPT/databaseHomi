# CLAUDE.md: Database Design - Room Service

The job objective is to design a dedicated database for the **Room Service** of the Homi 1.0 system. The design must ensure data normalization, flexibly support both DAILY and HOURLY rental models, and maintain the accuracy and integrity of inventory data (availability) even under high transaction volume.

## I. Functional Requirements

The design must address the following issues (compiled from Card 1 and Card 3):

### 1. Ensuring Accuracy and Concurrency Control

*   **Objective:** Strictly prevent a room from being booked by two people simultaneously (unsafe Overbooking), especially in a high-order volume environment (100k orders).
*   **Mechanism:** Use **Atomic Update** on the `room_availability` table when performing reservation holds (PENDING orders) or confirmation (CONFIRMED orders).
    *   **Update Logic (Atomic Update):**
        ```sql
        UPDATE room_availability 
        SET on_hold_units = on_hold_units + 1 
        WHERE id = :id 
        AND (total_units + overbooking_buffer - booked_units - on_hold_units) > 0 
        ```
    *   The update only proceeds if the "remaining space" is greater than 0, ensuring data integrity.

### 2. Supporting Flexible Rental Models (DAILY/HOURLY)

*   The data structure must support both daily (`DAILY`) and hourly (`HOURLY`) rentals.
*   The time calculation mechanism must include cleaning time (`buffer_minutes`) to ensure the continuity of hourly rental rooms.

### 3. Inventory Synchronization with OTAs (Inventory Sync)

Room Service needs to support three synchronization methods to prevent unintended Overbooking:

1.  **iCalendar (iCal Sync):** The basic method, using a recurring Cronjob (every 15-30 minutes) to retrieve data from the OTA's iCal URL and update the internal system. (Limitation: Not Real-time, delays of several hours, suitable for small scale).
2.  **Direct API Integration (Push/Pull):** Direct connection via the OTA's Connectivity API.
    *   **Push Protocol:** The internal system sends a POST request to the OTA's API upon a successful transaction to reduce the number of vacant rooms.
    *   **Pull/Webhook Protocol:** The OTA sends a Webhook back to the internal system when a transaction occurs on the OTA to lock the room inventory.
3.  **Channel Manager (Recommendation):** Establish a single communication gateway with a central Channel Manager API (SiteMinder, Channex). This is the modern standard, ensuring near real-time synchronization (under 5 seconds).

### 4. Managing Room Status After Check-out

*   **Issue:** Determining when a room becomes available (`avai`) after the guest `check-out` plus the cleaning time (`buffer_minutes`). This is more complex for hourly rentals.
*   **Manual Room Status Control:** When a Host/Admin changes a room status (e.g., from OPEN to CLOSED), the system must ensure no orders are currently in the PENDING state to prevent cases where a guest has paid but the room is subsequently closed.

### 5. Smartlock Integration Flow

*   The `rooms` table stores the `smartlock_device_id`.
*   **Automated Check-in Flow:** For homes with automated systems, the lock code is encrypted (`code_encrypted`) and provided to the guest via the app upon check-in, eliminating the need to contact the Host. (Encrypted data is stored in the `smartlock_codes` table of the Booking Service).

---

## II. Database Schema Design (Room Service Tables)

The Room Service Database design includes 6 main tables, ensuring data normalization.

### 1. `properties` Table (Accommodation Facility)

Defines the physical facilities (apartment complex, hotel, homestay chain).

| Column | Type | Description |
| :---: | :---: | :--- |
| **id** | UUID | PK |
| **host_id** | UUID | FK -> accounts (User Service) |
| **name** | VARCHAR | Facility name (E.g.: Homi Landmark 81) |
| **is_automated** | BOOLEAN | Flag to determine if automatic Smartlock is used |
| **is_dangerous** | BOOLEAN | Warning flag (used to block blacklisted/frequently reported locations) |
| **address** | TEXT | Physical address |

### 2. `rooms` Table (Configuration)

Defines the "functionality" and automation configuration of each room, supporting hourly rental.

| Column | Type | Constraint | Description |
| :---: | :---: | :---: | :--- |
| **id** | UUID | PK | |
| **property_id** | UUID | FK, NN | Links to properties(id) |
| **rental_type** | ENUM | NN, DEF DAILY | DAILY \| HOURLY \| BOTH |
| **hourly_price** | DECIMAL(12,2) | NULLABLE | Price per hour |
| **min_hours** | SMALLINT | DEF 2 | Minimum hours required for booking |
| **max_hours** | SMALLINT | NULLABLE | Maximum hour limit (null = unlimited) |
| **base_price** | DECIMAL(12,2) | NN | Default price per night |
| **smartlock_device_id** | VARCHAR(100) | NULLABLE | Smartlock device ID |

### 3. `room_types` Table (Room Categorization)

Helps normalize data, standardize amenities, and define maximum capacity.

| Column | Type | Description |
| :---: | :---: | :--- |
| **id** | UUID | PK |
| **property_id** | UUID | FK -> properties |
| **name** | VARCHAR | Room type name (E.g.: Deluxe Studio, Suite) |
| **amenities** | TEXT\[\] | List of amenities (Wifi, Bathtub, Kitchen...) |
| **max_guests** | SMALLINT | Maximum number of guests |

### 4. `room_media` Table (Image Library)

Manages the visual aspects of the room, a crucial factor for closing orders on platforms.

| Column | Type | Description |
| :---: | :---: | :--- |
| **id** | UUID | PK |
| **room_id** | UUID | FK -> rooms |
| **media_url** | VARCHAR | Link to image/video (S3/Cloudinary) |
| **media_type** | ENUM | IMAGE, VIDEO |
| **is_cover** | BOOLEAN | Representative cover image |
| **display_order** | SMALLINT | Display order in the app |

### 5. `room_availability` Table (Inventory Management)

Acts as the "gatekeeper" managing real-time availability, preventing Overbooking. Supports **Monthly Partitioning**.

| Column | Type | Constraint | Description |
| :---: | :---: | :---: | :--- |
| **id** | UUID | PK | gen_random_uuid() |
| **room_id** | UUID | FK, NN, IDX | Links to rooms(id) |
| **date** | DATE | NN, IDX | Specific date (YYYY-MM-DD) |
| **start_time** | TIME | NN | Slot start time (00:00 for daily rental) |
| **end_time** | TIME | NN | Slot end time (23:59 for daily rental) |
| **slot_type** | ENUM | NN | DAILY \| HOURLY |
| **total_units** | SMALLINT | NN | Total number of rooms of the same type |
| **booked_units** | SMALLINT | NN, DEF 0 | Number of CONFIRMED orders |
| **on_hold_units** | SMALLINT | NN, DEF 0 | Number of PENDING orders (reserved) |
| **overbooking_buffer** | SMALLINT | DEF 0 | Allows overselling (Homestay = 0) |
| **buffer_minutes** | SMALLINT | DEF 30 | Cleaning time between 2 bookings |
| **price_override** | DECIMAL(12,2) | NULLABLE | Price for this slot (null = use base price) |
| **status** | ENUM | NN, DEF OPEN | OPEN \| CLOSED \| BLOCKED |
| **created_at** | TIMESTAMPTZ | DEF now() | |

*   **UNIQUE constraint:** `(room_id, date, start_time, slot_type)`
*   **Composite index:** `(room_id, date, start_time, status)`
*   **Inventory Query Logic:** `SELECT room_id FROM room_availability WHERE date BETWEEN '15' AND '20' AND (total_units + overbooking_buffer - booked_units - on_hold_units) > 0 AND status = 'OPEN'`

### 6. `create_room_requests` Table (Approval Workflow)

Ensures quality by requiring Admin approval before a room can be listed for sale.

| Column | Type | Description |
| :---: | :---: | :--- |
| **id** | UUID | PK |
| **host_id** | UUID | FK -> accounts (User Service) |
| **property_data** | JSONB | Stores all room information entered by the Host |
| **status** | ENUM | PENDING, APPROVED, REJECTED |
| **admin_note** | TEXT | Reason for rejection (if any) |
| **reviewed_at** | TIMESTAMPTZ | Time of Admin review |

---

## III. Concurrency Control Mechanism (Concurrency & Lock)

To solve the issue of duplicate bookings in a high-traffic environment, the Homi 1.0 system will implement a combined solution using **Distributed Lock (Redis)** and **Pessimistic Locking (DB)**.

### 1. Comparison of Locking Mechanisms (When only 1 room remains)

| Mechanism | How It Works | Advantages | Disadvantages |
| :---: | :--- | :--- | :--- |
| **Pessimistic Locking** | Holds the key as soon as a customer inquires. The first one takes the key, subsequent ones wait at the door. | Absolute safety. Never any double booking. | Slow. If the key holder lingers too long, the long line of waiting people will cause a bottleneck (DB congestion). |
| **Optimistic Locking** | Allows everyone to check. The fastest one writes their name in the log first. Later arrivals are sent away if the log is filled. | Fast. No one has to wait in line. Fully utilizes DB power. | Prone to failure. If 100 people "rush" for 1 room during a Flash sale, 99 people will get a "try again" error, creating a large conflict (Retry storm). |
| **Distributed Lock (Redis)** | Places a ticket machine at the hotel entrance. Only those with a ticket can meet the receptionist. | Extremely fast response. People without a ticket leave immediately, not bothering the receptionist (DB). | Dependency on a third party. If the ticket machine (Redis) fails, the security guard won't know whom to let in. |

### 2. Combined Solution

*   **Distributed Lock (Redis):** Checks the `Idempotency-Key`. If the key already exists (the user has already clicked reserve/pay), the system rejects duplicate requests (maintaining extremely fast response for the user).
*   **Pessimistic Locking (DB):** When the Client brings the key to the DB, `Pessimistic Locking` performs a `SELECT FOR UPDATE` to lock the row in the `room_availability` table. This ensures no other transaction can jump in and modify the room count while calculations are being made.

### 3. 2-TRANSACTION BOOKING ARCHITECTURE

This mechanism divides the booking process into **two separate stages** to optimize DB performance and user experience.

#### Stage 1: Temporary Hold

*   **Timing:** Immediately when the user clicks the "Pay" button.
*   **Action at DB:**
    1.  Open a Transaction, perform **Pessimistic Lock** (`SELECT FOR UPDATE`) on the `room_availability` table to exclusively check the room count.
    2.  If rooms are available: Increase `booked_units` by 1 unit.
    3.  Create a record in the `bookings` table with status `PENDING_PAYMENT`, attached with an `Idempotency-Key` to prevent duplication.
*   **Conclusion:** Execute `COMMIT` immediately. The Lock exists for only a few milliseconds.

#### Intermediate Stage: Awaiting Payment

*   **Timing:** The screen displays the VietQR code (usually allowed for 10-15 minutes).
*   **Lock Status:** Absolutely no Lock exists in the DB; connections are completely idle.
*   **Subsequent User Experience:** If another person tries to book the same room, the DB will report "No rooms available" based on the updated `booked_units` count, not due to being "stuck" waiting for a Lock.

#### Stage 2: Completion or Reversal

Processing based on the actual payment result from the customer.

**1. Payment Failed or Canceled (Real-time Error)**
*   **Processing:** The Backend receives the signal, immediately opens a very short Transaction to:
    *   Change the Booking status to `CANCELLED`.
    *   Decrease `booked_units` by 1 unit (Returning the room to inventory).

**2. Guest "Silently" Leaves**
*   **Processing:** Use a Cron Job (running every 5-10 minutes) to scan for `PENDING_PAYMENT` orders that have expired (e.g., 10 minutes).
    *   Automatically cancel the order and add the room back to the inventory data.

### 4. Effectiveness of the 2-Transaction Mechanism

1.  **Anti-Congestion (No Bottleneck):** The DB is never locked for more than 0.1 seconds. The system runs extremely smoothly even under high traffic.
2.  **Accuracy (Consistency):** Thanks to the short-term `SELECT FOR UPDATE` in Stage 1, the room count is strictly controlled, ensuring no overselling (Overbooking).
3.  **Resource Optimization:** Your server can handle hundreds of simultaneous customers because it does not have to "sustain" long-held DB connections.