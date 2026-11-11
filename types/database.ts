
export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[]

export type Database = {
  
  "graphql_public": {
          Tables: {
            [_ in never]: never
          }
          Views: {
            [_ in never]: never
          }
          Functions: {
            "graphql":
{ Args: { "extensions"?: Json,"operationName"?: string,"query"?: string,"variables"?: Json }; Returns: Json
                           }
          }
          Enums: {
            [_ in never]: never
          }
          CompositeTypes: {
            [_ in never]: never
          }
        },"public": {
          Tables: {
            "banned_phones": {
                  Row: {
                    "banned_by": string | null,"created_at": string,"phone": string,"reason": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "banned_by"?: string | null,"created_at"?: string,"phone": string,"reason"?: string | null
                  }
                  Update: {
                    "banned_by"?: string | null,"created_at"?: string,"phone"?: string,"reason"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "banned_phones_banned_by_fkey"
      columns: ["banned_by"]
isOneToOne: false
      referencedRelation: "driver_wallet"
      referencedColumns: ["user_id"]
    },{
      foreignKeyName: "banned_phones_banned_by_fkey"
      columns: ["banned_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "banned_phones_banned_by_fkey"
      columns: ["banned_by"]
isOneToOne: false
      referencedRelation: "profiles_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "banned_phones_banned_by_fkey"
      columns: ["banned_by"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["driver_id"]
    }
                  ]
                },"bookings": {
                  Row: {
                    "cancel_reason": string | null,"cancelled_at": string | null,"cancelled_by": Database["public"]['Enums']["party"] | null,"completed_at": string | null,"created_at": string,"driver_confirmed_at": string | null,"fee_kz": number,"id": string,"message": string | null,"passenger_confirmed_at": string | null,"passenger_id": string,"pin_code": string | null,"pin_entered_at": string | null,"pin_sent_at": string | null,"price_total_kz": number,"refund_kz": number,"requested_at": string | null,"responded_at": string | null,"seats": number,"status": Database["public"]['Enums']["booking_status"],"trip_id": string,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "cancel_reason"?: string | null,"cancelled_at"?: string | null,"cancelled_by"?: Database["public"]['Enums']["party"] | null,"completed_at"?: string | null,"created_at"?: string,"driver_confirmed_at"?: string | null,"fee_kz": number,"id"?: string,"message"?: string | null,"passenger_confirmed_at"?: string | null,"passenger_id": string,"pin_code"?: string | null,"pin_entered_at"?: string | null,"pin_sent_at"?: string | null,"price_total_kz": number,"refund_kz"?: number,"requested_at"?: string | null,"responded_at"?: string | null,"seats": number,"status"?: Database["public"]['Enums']["booking_status"],"trip_id": string,"updated_at"?: string
                  }
                  Update: {
                    "cancel_reason"?: string | null,"cancelled_at"?: string | null,"cancelled_by"?: Database["public"]['Enums']["party"] | null,"completed_at"?: string | null,"created_at"?: string,"driver_confirmed_at"?: string | null,"fee_kz"?: number,"id"?: string,"message"?: string | null,"passenger_confirmed_at"?: string | null,"passenger_id"?: string,"pin_code"?: string | null,"pin_entered_at"?: string | null,"pin_sent_at"?: string | null,"price_total_kz"?: number,"refund_kz"?: number,"requested_at"?: string | null,"responded_at"?: string | null,"seats"?: number,"status"?: Database["public"]['Enums']["booking_status"],"trip_id"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "bookings_passenger_id_fkey"
      columns: ["passenger_id"]
isOneToOne: false
      referencedRelation: "driver_wallet"
      referencedColumns: ["user_id"]
    },{
      foreignKeyName: "bookings_passenger_id_fkey"
      columns: ["passenger_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "bookings_passenger_id_fkey"
      columns: ["passenger_id"]
isOneToOne: false
      referencedRelation: "profiles_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "bookings_passenger_id_fkey"
      columns: ["passenger_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["driver_id"]
    },{
      foreignKeyName: "bookings_trip_id_fkey"
      columns: ["trip_id"]
isOneToOne: false
      referencedRelation: "trips"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "bookings_trip_id_fkey"
      columns: ["trip_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["id"]
    }
                  ]
                },"contact_reveals": {
                  Row: {
                    "booking_id": string,"created_at": string,"id": string,"revealed_user_id": string,"viewer_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "booking_id": string,"created_at"?: string,"id"?: string,"revealed_user_id": string,"viewer_id": string
                  }
                  Update: {
                    "booking_id"?: string,"created_at"?: string,"id"?: string,"revealed_user_id"?: string,"viewer_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "contact_reveals_booking_id_fkey"
      columns: ["booking_id"]
isOneToOne: false
      referencedRelation: "bookings"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "contact_reveals_booking_id_fkey"
      columns: ["booking_id"]
isOneToOne: false
      referencedRelation: "my_bookings"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "contact_reveals_revealed_user_id_fkey"
      columns: ["revealed_user_id"]
isOneToOne: false
      referencedRelation: "driver_wallet"
      referencedColumns: ["user_id"]
    },{
      foreignKeyName: "contact_reveals_revealed_user_id_fkey"
      columns: ["revealed_user_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "contact_reveals_revealed_user_id_fkey"
      columns: ["revealed_user_id"]
isOneToOne: false
      referencedRelation: "profiles_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "contact_reveals_revealed_user_id_fkey"
      columns: ["revealed_user_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["driver_id"]
    },{
      foreignKeyName: "contact_reveals_viewer_id_fkey"
      columns: ["viewer_id"]
isOneToOne: false
      referencedRelation: "driver_wallet"
      referencedColumns: ["user_id"]
    },{
      foreignKeyName: "contact_reveals_viewer_id_fkey"
      columns: ["viewer_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "contact_reveals_viewer_id_fkey"
      columns: ["viewer_id"]
isOneToOne: false
      referencedRelation: "profiles_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "contact_reveals_viewer_id_fkey"
      columns: ["viewer_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["driver_id"]
    }
                  ]
                },"conversations": {
                  Row: {
                    "booking_id": string | null,"closed_at": string | null,"created_at": string,"driver_id": string,"driver_seen_at": string | null,"id": string,"last_message_at": string | null,"passenger_id": string,"passenger_seen_at": string | null,"trip_id": string,"updated_at": string,"admin_can_see_conversation": boolean | null,"conversation_paid": boolean | null
                  }
                  ComputedFields: "admin_can_see_conversation" | "conversation_paid"
                  Insert: {
                    "booking_id"?: string | null,"closed_at"?: string | null,"created_at"?: string,"driver_id": string,"driver_seen_at"?: string | null,"id"?: string,"last_message_at"?: string | null,"passenger_id": string,"passenger_seen_at"?: string | null,"trip_id": string,"updated_at"?: string
                  }
                  Update: {
                    "booking_id"?: string | null,"closed_at"?: string | null,"created_at"?: string,"driver_id"?: string,"driver_seen_at"?: string | null,"id"?: string,"last_message_at"?: string | null,"passenger_id"?: string,"passenger_seen_at"?: string | null,"trip_id"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "conversations_booking_id_fkey"
      columns: ["booking_id"]
isOneToOne: false
      referencedRelation: "bookings"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "conversations_booking_id_fkey"
      columns: ["booking_id"]
isOneToOne: false
      referencedRelation: "my_bookings"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "conversations_driver_id_fkey"
      columns: ["driver_id"]
isOneToOne: false
      referencedRelation: "driver_wallet"
      referencedColumns: ["user_id"]
    },{
      foreignKeyName: "conversations_driver_id_fkey"
      columns: ["driver_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "conversations_driver_id_fkey"
      columns: ["driver_id"]
isOneToOne: false
      referencedRelation: "profiles_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "conversations_driver_id_fkey"
      columns: ["driver_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["driver_id"]
    },{
      foreignKeyName: "conversations_passenger_id_fkey"
      columns: ["passenger_id"]
isOneToOne: false
      referencedRelation: "driver_wallet"
      referencedColumns: ["user_id"]
    },{
      foreignKeyName: "conversations_passenger_id_fkey"
      columns: ["passenger_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "conversations_passenger_id_fkey"
      columns: ["passenger_id"]
isOneToOne: false
      referencedRelation: "profiles_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "conversations_passenger_id_fkey"
      columns: ["passenger_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["driver_id"]
    },{
      foreignKeyName: "conversations_trip_id_fkey"
      columns: ["trip_id"]
isOneToOne: false
      referencedRelation: "trips"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "conversations_trip_id_fkey"
      columns: ["trip_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["id"]
    }
                  ]
                },"devices": {
                  Row: {
                    "app_version": string | null,"created_at": string,"id": string,"last_seen_at": string,"platform": Database["public"]['Enums']["platform"],"push_token": string,"user_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "app_version"?: string | null,"created_at"?: string,"id"?: string,"last_seen_at"?: string,"platform": Database["public"]['Enums']["platform"],"push_token": string,"user_id": string
                  }
                  Update: {
                    "app_version"?: string | null,"created_at"?: string,"id"?: string,"last_seen_at"?: string,"platform"?: Database["public"]['Enums']["platform"],"push_token"?: string,"user_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "devices_user_id_fkey"
      columns: ["user_id"]
isOneToOne: false
      referencedRelation: "driver_wallet"
      referencedColumns: ["user_id"]
    },{
      foreignKeyName: "devices_user_id_fkey"
      columns: ["user_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "devices_user_id_fkey"
      columns: ["user_id"]
isOneToOne: false
      referencedRelation: "profiles_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "devices_user_id_fkey"
      columns: ["user_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["driver_id"]
    }
                  ]
                },"driver_verifications": {
                  Row: {
                    "created_at": string,"id": string,"id_doc_url": string | null,"licence_url": string | null,"reject_reason": string | null,"reviewed_at": string | null,"reviewed_by": string | null,"selfie_url": string | null,"status": Database["public"]['Enums']["verification_status"],"updated_at": string,"user_id": string,"vehicle_id": string,"vehicle_photo_url": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"id"?: string,"id_doc_url"?: string | null,"licence_url"?: string | null,"reject_reason"?: string | null,"reviewed_at"?: string | null,"reviewed_by"?: string | null,"selfie_url"?: string | null,"status"?: Database["public"]['Enums']["verification_status"],"updated_at"?: string,"user_id": string,"vehicle_id": string,"vehicle_photo_url"?: string | null
                  }
                  Update: {
                    "created_at"?: string,"id"?: string,"id_doc_url"?: string | null,"licence_url"?: string | null,"reject_reason"?: string | null,"reviewed_at"?: string | null,"reviewed_by"?: string | null,"selfie_url"?: string | null,"status"?: Database["public"]['Enums']["verification_status"],"updated_at"?: string,"user_id"?: string,"vehicle_id"?: string,"vehicle_photo_url"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "driver_verifications_reviewed_by_fkey"
      columns: ["reviewed_by"]
isOneToOne: false
      referencedRelation: "driver_wallet"
      referencedColumns: ["user_id"]
    },{
      foreignKeyName: "driver_verifications_reviewed_by_fkey"
      columns: ["reviewed_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "driver_verifications_reviewed_by_fkey"
      columns: ["reviewed_by"]
isOneToOne: false
      referencedRelation: "profiles_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "driver_verifications_reviewed_by_fkey"
      columns: ["reviewed_by"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["driver_id"]
    },{
      foreignKeyName: "driver_verifications_user_id_fkey"
      columns: ["user_id"]
isOneToOne: false
      referencedRelation: "driver_wallet"
      referencedColumns: ["user_id"]
    },{
      foreignKeyName: "driver_verifications_user_id_fkey"
      columns: ["user_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "driver_verifications_user_id_fkey"
      columns: ["user_id"]
isOneToOne: false
      referencedRelation: "profiles_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "driver_verifications_user_id_fkey"
      columns: ["user_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["driver_id"]
    },{
      foreignKeyName: "driver_verifications_vehicle_id_fkey"
      columns: ["vehicle_id"]
isOneToOne: false
      referencedRelation: "vehicles"
      referencedColumns: ["id"]
    }
                  ]
                },"events": {
                  Row: {
                    "created_at": string,"id": number,"name": string,"platform": Database["public"]['Enums']["platform"] | null,"props": NonNullable<Json>,"user_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"id"?: never,"name": string,"platform"?: Database["public"]['Enums']["platform"] | null,"props"?: NonNullable<Json>,"user_id"?: string | null
                  }
                  Update: {
                    "created_at"?: string,"id"?: never,"name"?: string,"platform"?: Database["public"]['Enums']["platform"] | null,"props"?: NonNullable<Json>,"user_id"?: string | null
                  }
                  Relationships: [
                    
                  ]
                },"ledger_entries": {
                  Row: {
                    "account": Database["public"]['Enums']["ledger_account"],"amount_kz": number,"booking_id": string | null,"created_at": string,"id": number,"memo": string | null,"op_id": string,"payout_id": string | null,"user_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "account": Database["public"]['Enums']["ledger_account"],"amount_kz": number,"booking_id"?: string | null,"created_at"?: string,"id"?: never,"memo"?: string | null,"op_id": string,"payout_id"?: string | null,"user_id"?: string | null
                  }
                  Update: {
                    "account"?: Database["public"]['Enums']["ledger_account"],"amount_kz"?: number,"booking_id"?: string | null,"created_at"?: string,"id"?: never,"memo"?: string | null,"op_id"?: string,"payout_id"?: string | null,"user_id"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "ledger_entries_booking_id_fkey"
      columns: ["booking_id"]
isOneToOne: false
      referencedRelation: "bookings"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "ledger_entries_booking_id_fkey"
      columns: ["booking_id"]
isOneToOne: false
      referencedRelation: "my_bookings"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "ledger_entries_user_id_fkey"
      columns: ["user_id"]
isOneToOne: false
      referencedRelation: "driver_wallet"
      referencedColumns: ["user_id"]
    },{
      foreignKeyName: "ledger_entries_user_id_fkey"
      columns: ["user_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "ledger_entries_user_id_fkey"
      columns: ["user_id"]
isOneToOne: false
      referencedRelation: "profiles_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "ledger_entries_user_id_fkey"
      columns: ["user_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["driver_id"]
    },{
      foreignKeyName: "ledger_payout_fk"
      columns: ["payout_id"]
isOneToOne: false
      referencedRelation: "payouts"
      referencedColumns: ["id"]
    }
                  ]
                },"messages": {
                  Row: {
                    "body": string,"conversation_id": string,"created_at": string,"id": number,"masked": boolean,"read_at": string | null,"sender_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "body": string,"conversation_id": string,"created_at"?: string,"id"?: never,"masked"?: boolean,"read_at"?: string | null,"sender_id"?: string | null
                  }
                  Update: {
                    "body"?: string,"conversation_id"?: string,"created_at"?: string,"id"?: never,"masked"?: boolean,"read_at"?: string | null,"sender_id"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "messages_conversation_id_fkey"
      columns: ["conversation_id"]
isOneToOne: false
      referencedRelation: "conversations"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "messages_conversation_id_fkey"
      columns: ["conversation_id"]
isOneToOne: false
      referencedRelation: "my_bookings"
      referencedColumns: ["conversation_id"]
    },{
      foreignKeyName: "messages_conversation_id_fkey"
      columns: ["conversation_id"]
isOneToOne: false
      referencedRelation: "my_conversations"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "messages_sender_id_fkey"
      columns: ["sender_id"]
isOneToOne: false
      referencedRelation: "driver_wallet"
      referencedColumns: ["user_id"]
    },{
      foreignKeyName: "messages_sender_id_fkey"
      columns: ["sender_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "messages_sender_id_fkey"
      columns: ["sender_id"]
isOneToOne: false
      referencedRelation: "profiles_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "messages_sender_id_fkey"
      columns: ["sender_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["driver_id"]
    }
                  ]
                },"moderation_actions": {
                  Row: {
                    "action": Database["public"]['Enums']["mod_action"],"admin_id": string,"created_at": string,"id": string,"payload": NonNullable<Json>,"reason": string | null,"report_id": string | null,"target_user_id": string,"until": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "action": Database["public"]['Enums']["mod_action"],"admin_id": string,"created_at"?: string,"id"?: string,"payload"?: NonNullable<Json>,"reason"?: string | null,"report_id"?: string | null,"target_user_id": string,"until"?: string | null
                  }
                  Update: {
                    "action"?: Database["public"]['Enums']["mod_action"],"admin_id"?: string,"created_at"?: string,"id"?: string,"payload"?: NonNullable<Json>,"reason"?: string | null,"report_id"?: string | null,"target_user_id"?: string,"until"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "moderation_actions_admin_id_fkey"
      columns: ["admin_id"]
isOneToOne: false
      referencedRelation: "driver_wallet"
      referencedColumns: ["user_id"]
    },{
      foreignKeyName: "moderation_actions_admin_id_fkey"
      columns: ["admin_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "moderation_actions_admin_id_fkey"
      columns: ["admin_id"]
isOneToOne: false
      referencedRelation: "profiles_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "moderation_actions_admin_id_fkey"
      columns: ["admin_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["driver_id"]
    },{
      foreignKeyName: "moderation_actions_report_id_fkey"
      columns: ["report_id"]
isOneToOne: false
      referencedRelation: "reports"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "moderation_actions_target_user_id_fkey"
      columns: ["target_user_id"]
isOneToOne: false
      referencedRelation: "driver_wallet"
      referencedColumns: ["user_id"]
    },{
      foreignKeyName: "moderation_actions_target_user_id_fkey"
      columns: ["target_user_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "moderation_actions_target_user_id_fkey"
      columns: ["target_user_id"]
isOneToOne: false
      referencedRelation: "profiles_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "moderation_actions_target_user_id_fkey"
      columns: ["target_user_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["driver_id"]
    }
                  ]
                },"notifications": {
                  Row: {
                    "channel": Database["public"]['Enums']["notif_channel"],"created_at": string,"error": string | null,"id": string,"payload": NonNullable<Json>,"read_at": string | null,"scheduled_for": string | null,"sent_at": string | null,"status": Database["public"]['Enums']["notif_status"],"type": string,"user_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "channel": Database["public"]['Enums']["notif_channel"],"created_at"?: string,"error"?: string | null,"id"?: string,"payload"?: NonNullable<Json>,"read_at"?: string | null,"scheduled_for"?: string | null,"sent_at"?: string | null,"status"?: Database["public"]['Enums']["notif_status"],"type": string,"user_id": string
                  }
                  Update: {
                    "channel"?: Database["public"]['Enums']["notif_channel"],"created_at"?: string,"error"?: string | null,"id"?: string,"payload"?: NonNullable<Json>,"read_at"?: string | null,"scheduled_for"?: string | null,"sent_at"?: string | null,"status"?: Database["public"]['Enums']["notif_status"],"type"?: string,"user_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "notifications_user_id_fkey"
      columns: ["user_id"]
isOneToOne: false
      referencedRelation: "driver_wallet"
      referencedColumns: ["user_id"]
    },{
      foreignKeyName: "notifications_user_id_fkey"
      columns: ["user_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "notifications_user_id_fkey"
      columns: ["user_id"]
isOneToOne: false
      referencedRelation: "profiles_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "notifications_user_id_fkey"
      columns: ["user_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["driver_id"]
    }
                  ]
                },"payments": {
                  Row: {
                    "amount_kz": number,"booking_id": string,"created_at": string,"expires_at": string | null,"id": string,"paid_at": string | null,"payer_id": string,"provider": string,"provider_ref": string | null,"raw_request": Json | null,"raw_webhook": Json | null,"refund_attempts": number,"refund_failed_at": string | null,"refund_kz": number,"refund_ref": string | null,"refunded_at": string | null,"status": Database["public"]['Enums']["payment_status"],"updated_at": string,"ledger_payment": undefined | null
                  }
                  ComputedFields: "ledger_payment"
                  Insert: {
                    "amount_kz": number,"booking_id": string,"created_at"?: string,"expires_at"?: string | null,"id"?: string,"paid_at"?: string | null,"payer_id": string,"provider"?: string,"provider_ref"?: string | null,"raw_request"?: Json | null,"raw_webhook"?: Json | null,"refund_attempts"?: number,"refund_failed_at"?: string | null,"refund_kz"?: number,"refund_ref"?: string | null,"refunded_at"?: string | null,"status"?: Database["public"]['Enums']["payment_status"],"updated_at"?: string
                  }
                  Update: {
                    "amount_kz"?: number,"booking_id"?: string,"created_at"?: string,"expires_at"?: string | null,"id"?: string,"paid_at"?: string | null,"payer_id"?: string,"provider"?: string,"provider_ref"?: string | null,"raw_request"?: Json | null,"raw_webhook"?: Json | null,"refund_attempts"?: number,"refund_failed_at"?: string | null,"refund_kz"?: number,"refund_ref"?: string | null,"refunded_at"?: string | null,"status"?: Database["public"]['Enums']["payment_status"],"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "payments_booking_id_fkey"
      columns: ["booking_id"]
isOneToOne: false
      referencedRelation: "bookings"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "payments_booking_id_fkey"
      columns: ["booking_id"]
isOneToOne: false
      referencedRelation: "my_bookings"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "payments_payer_id_fkey"
      columns: ["payer_id"]
isOneToOne: false
      referencedRelation: "driver_wallet"
      referencedColumns: ["user_id"]
    },{
      foreignKeyName: "payments_payer_id_fkey"
      columns: ["payer_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "payments_payer_id_fkey"
      columns: ["payer_id"]
isOneToOne: false
      referencedRelation: "profiles_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "payments_payer_id_fkey"
      columns: ["payer_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["driver_id"]
    }
                  ]
                },"payouts": {
                  Row: {
                    "amount_kz": number,"created_at": string,"id": string,"method": NonNullable<Json>,"processed_at": string | null,"processed_by": string | null,"provider_ref": string | null,"status": Database["public"]['Enums']["payout_status"],"updated_at": string,"user_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "amount_kz": number,"created_at"?: string,"id"?: string,"method": NonNullable<Json>,"processed_at"?: string | null,"processed_by"?: string | null,"provider_ref"?: string | null,"status"?: Database["public"]['Enums']["payout_status"],"updated_at"?: string,"user_id": string
                  }
                  Update: {
                    "amount_kz"?: number,"created_at"?: string,"id"?: string,"method"?: NonNullable<Json>,"processed_at"?: string | null,"processed_by"?: string | null,"provider_ref"?: string | null,"status"?: Database["public"]['Enums']["payout_status"],"updated_at"?: string,"user_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "payouts_processed_by_fkey"
      columns: ["processed_by"]
isOneToOne: false
      referencedRelation: "driver_wallet"
      referencedColumns: ["user_id"]
    },{
      foreignKeyName: "payouts_processed_by_fkey"
      columns: ["processed_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "payouts_processed_by_fkey"
      columns: ["processed_by"]
isOneToOne: false
      referencedRelation: "profiles_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "payouts_processed_by_fkey"
      columns: ["processed_by"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["driver_id"]
    },{
      foreignKeyName: "payouts_user_id_fkey"
      columns: ["user_id"]
isOneToOne: false
      referencedRelation: "driver_wallet"
      referencedColumns: ["user_id"]
    },{
      foreignKeyName: "payouts_user_id_fkey"
      columns: ["user_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "payouts_user_id_fkey"
      columns: ["user_id"]
isOneToOne: false
      referencedRelation: "profiles_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "payouts_user_id_fkey"
      columns: ["user_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["driver_id"]
    }
                  ]
                },"places": {
                  Row: {
                    "aliases": (string)[],"created_at": string,"id": string,"is_active": boolean,"kind": Database["public"]['Enums']["place_kind"],"lat": number | null,"lng": number | null,"name": string,"province": string,"slug": string,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "aliases"?: (string)[],"created_at"?: string,"id"?: string,"is_active"?: boolean,"kind"?: Database["public"]['Enums']["place_kind"],"lat"?: number | null,"lng"?: number | null,"name": string,"province": string,"slug": string,"updated_at"?: string
                  }
                  Update: {
                    "aliases"?: (string)[],"created_at"?: string,"id"?: string,"is_active"?: boolean,"kind"?: Database["public"]['Enums']["place_kind"],"lat"?: number | null,"lng"?: number | null,"name"?: string,"province"?: string,"slug"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    
                  ]
                },"profiles": {
                  Row: {
                    "adult_confirmed_at": string | null,"avatar_url": string | null,"balance_kz": number,"bio": string | null,"birth_year": number | null,"cancels_total": number,"chat_level": Database["public"]['Enums']["chat_level"],"created_at": string,"display_name": string,"driver_status": Database["public"]['Enums']["driver_status"],"driver_verified_at": string | null,"id": string,"is_admin": boolean,"last_seen_at": string | null,"locale": string,"no_shows": number,"payout_method": Json | null,"phone": string | null,"phone_verified_at": string | null,"rating_avg": number,"rating_count": number,"status": Database["public"]['Enums']["profile_status"],"suspended_until": string | null,"terms_accepted_at": string | null,"trips_driven": number,"trips_ridden": number,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "adult_confirmed_at"?: string | null,"avatar_url"?: string | null,"balance_kz"?: number,"bio"?: string | null,"birth_year"?: number | null,"cancels_total"?: number,"chat_level"?: Database["public"]['Enums']["chat_level"],"created_at"?: string,"display_name"?: string,"driver_status"?: Database["public"]['Enums']["driver_status"],"driver_verified_at"?: string | null,"id": string,"is_admin"?: boolean,"last_seen_at"?: string | null,"locale"?: string,"no_shows"?: number,"payout_method"?: Json | null,"phone"?: string | null,"phone_verified_at"?: string | null,"rating_avg"?: number,"rating_count"?: number,"status"?: Database["public"]['Enums']["profile_status"],"suspended_until"?: string | null,"terms_accepted_at"?: string | null,"trips_driven"?: number,"trips_ridden"?: number,"updated_at"?: string
                  }
                  Update: {
                    "adult_confirmed_at"?: string | null,"avatar_url"?: string | null,"balance_kz"?: number,"bio"?: string | null,"birth_year"?: number | null,"cancels_total"?: number,"chat_level"?: Database["public"]['Enums']["chat_level"],"created_at"?: string,"display_name"?: string,"driver_status"?: Database["public"]['Enums']["driver_status"],"driver_verified_at"?: string | null,"id"?: string,"is_admin"?: boolean,"last_seen_at"?: string | null,"locale"?: string,"no_shows"?: number,"payout_method"?: Json | null,"phone"?: string | null,"phone_verified_at"?: string | null,"rating_avg"?: number,"rating_count"?: number,"status"?: Database["public"]['Enums']["profile_status"],"suspended_until"?: string | null,"terms_accepted_at"?: string | null,"trips_driven"?: number,"trips_ridden"?: number,"updated_at"?: string
                  }
                  Relationships: [
                    
                  ]
                },"reports": {
                  Row: {
                    "booking_id": string | null,"created_at": string,"details": string | null,"id": string,"message_id": number | null,"reason": Database["public"]['Enums']["report_reason"],"reporter_id": string | null,"resolved_by": string | null,"status": Database["public"]['Enums']["report_status"],"target_user_id": string,"trip_id": string | null,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "booking_id"?: string | null,"created_at"?: string,"details"?: string | null,"id"?: string,"message_id"?: number | null,"reason": Database["public"]['Enums']["report_reason"],"reporter_id"?: string | null,"resolved_by"?: string | null,"status"?: Database["public"]['Enums']["report_status"],"target_user_id": string,"trip_id"?: string | null,"updated_at"?: string
                  }
                  Update: {
                    "booking_id"?: string | null,"created_at"?: string,"details"?: string | null,"id"?: string,"message_id"?: number | null,"reason"?: Database["public"]['Enums']["report_reason"],"reporter_id"?: string | null,"resolved_by"?: string | null,"status"?: Database["public"]['Enums']["report_status"],"target_user_id"?: string,"trip_id"?: string | null,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "reports_booking_id_fkey"
      columns: ["booking_id"]
isOneToOne: false
      referencedRelation: "bookings"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "reports_booking_id_fkey"
      columns: ["booking_id"]
isOneToOne: false
      referencedRelation: "my_bookings"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "reports_message_id_fkey"
      columns: ["message_id"]
isOneToOne: false
      referencedRelation: "messages"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "reports_reporter_id_fkey"
      columns: ["reporter_id"]
isOneToOne: false
      referencedRelation: "driver_wallet"
      referencedColumns: ["user_id"]
    },{
      foreignKeyName: "reports_reporter_id_fkey"
      columns: ["reporter_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "reports_reporter_id_fkey"
      columns: ["reporter_id"]
isOneToOne: false
      referencedRelation: "profiles_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "reports_reporter_id_fkey"
      columns: ["reporter_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["driver_id"]
    },{
      foreignKeyName: "reports_resolved_by_fkey"
      columns: ["resolved_by"]
isOneToOne: false
      referencedRelation: "driver_wallet"
      referencedColumns: ["user_id"]
    },{
      foreignKeyName: "reports_resolved_by_fkey"
      columns: ["resolved_by"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "reports_resolved_by_fkey"
      columns: ["resolved_by"]
isOneToOne: false
      referencedRelation: "profiles_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "reports_resolved_by_fkey"
      columns: ["resolved_by"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["driver_id"]
    },{
      foreignKeyName: "reports_target_user_id_fkey"
      columns: ["target_user_id"]
isOneToOne: false
      referencedRelation: "driver_wallet"
      referencedColumns: ["user_id"]
    },{
      foreignKeyName: "reports_target_user_id_fkey"
      columns: ["target_user_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "reports_target_user_id_fkey"
      columns: ["target_user_id"]
isOneToOne: false
      referencedRelation: "profiles_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "reports_target_user_id_fkey"
      columns: ["target_user_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["driver_id"]
    },{
      foreignKeyName: "reports_trip_id_fkey"
      columns: ["trip_id"]
isOneToOne: false
      referencedRelation: "trips"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "reports_trip_id_fkey"
      columns: ["trip_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["id"]
    }
                  ]
                },"reviews": {
                  Row: {
                    "author_id": string,"booking_id": string,"comment": string | null,"created_at": string,"direction": Database["public"]['Enums']["review_direction"],"id": string,"is_visible": boolean,"rating": number,"tags": (string)[],"target_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "author_id": string,"booking_id": string,"comment"?: string | null,"created_at"?: string,"direction": Database["public"]['Enums']["review_direction"],"id"?: string,"is_visible"?: boolean,"rating": number,"tags"?: (string)[],"target_id": string
                  }
                  Update: {
                    "author_id"?: string,"booking_id"?: string,"comment"?: string | null,"created_at"?: string,"direction"?: Database["public"]['Enums']["review_direction"],"id"?: string,"is_visible"?: boolean,"rating"?: number,"tags"?: (string)[],"target_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "reviews_author_id_fkey"
      columns: ["author_id"]
isOneToOne: false
      referencedRelation: "driver_wallet"
      referencedColumns: ["user_id"]
    },{
      foreignKeyName: "reviews_author_id_fkey"
      columns: ["author_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "reviews_author_id_fkey"
      columns: ["author_id"]
isOneToOne: false
      referencedRelation: "profiles_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "reviews_author_id_fkey"
      columns: ["author_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["driver_id"]
    },{
      foreignKeyName: "reviews_booking_id_fkey"
      columns: ["booking_id"]
isOneToOne: false
      referencedRelation: "bookings"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "reviews_booking_id_fkey"
      columns: ["booking_id"]
isOneToOne: false
      referencedRelation: "my_bookings"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "reviews_target_id_fkey"
      columns: ["target_id"]
isOneToOne: false
      referencedRelation: "driver_wallet"
      referencedColumns: ["user_id"]
    },{
      foreignKeyName: "reviews_target_id_fkey"
      columns: ["target_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "reviews_target_id_fkey"
      columns: ["target_id"]
isOneToOne: false
      referencedRelation: "profiles_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "reviews_target_id_fkey"
      columns: ["target_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["driver_id"]
    }
                  ]
                },"route_durations": {
                  Row: {
                    "destination_place_id": string,"minutes": number,"origin_place_id": string,"price_hint_kz": number | null
                  }
                  ComputedFields: never
                  Insert: {
                    "destination_place_id": string,"minutes": number,"origin_place_id": string,"price_hint_kz"?: number | null
                  }
                  Update: {
                    "destination_place_id"?: string,"minutes"?: number,"origin_place_id"?: string,"price_hint_kz"?: number | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "route_durations_destination_place_id_fkey"
      columns: ["destination_place_id"]
isOneToOne: false
      referencedRelation: "places"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "route_durations_destination_place_id_fkey"
      columns: ["destination_place_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["destination_place_id"]
    },{
      foreignKeyName: "route_durations_destination_place_id_fkey"
      columns: ["destination_place_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["origin_place_id"]
    },{
      foreignKeyName: "route_durations_origin_place_id_fkey"
      columns: ["origin_place_id"]
isOneToOne: false
      referencedRelation: "places"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "route_durations_origin_place_id_fkey"
      columns: ["origin_place_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["destination_place_id"]
    },{
      foreignKeyName: "route_durations_origin_place_id_fkey"
      columns: ["origin_place_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["origin_place_id"]
    }
                  ]
                },"scheduler_jobs": {
                  Row: {
                    "last_error": string | null,"last_ok_at": string | null,"last_run_at": string | null,"name": string,"runs": number
                  }
                  ComputedFields: never
                  Insert: {
                    "last_error"?: string | null,"last_ok_at"?: string | null,"last_run_at"?: string | null,"name": string,"runs"?: number
                  }
                  Update: {
                    "last_error"?: string | null,"last_ok_at"?: string | null,"last_run_at"?: string | null,"name"?: string,"runs"?: number
                  }
                  Relationships: [
                    
                  ]
                },"trip_stops": {
                  Row: {
                    "id": string,"order_idx": number,"place_id": string,"price_from_origin_kz": number | null,"trip_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "id"?: string,"order_idx": number,"place_id": string,"price_from_origin_kz"?: number | null,"trip_id": string
                  }
                  Update: {
                    "id"?: string,"order_idx"?: number,"place_id"?: string,"price_from_origin_kz"?: number | null,"trip_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "trip_stops_place_id_fkey"
      columns: ["place_id"]
isOneToOne: false
      referencedRelation: "places"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "trip_stops_place_id_fkey"
      columns: ["place_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["destination_place_id"]
    },{
      foreignKeyName: "trip_stops_place_id_fkey"
      columns: ["place_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["origin_place_id"]
    },{
      foreignKeyName: "trip_stops_trip_id_fkey"
      columns: ["trip_id"]
isOneToOne: false
      referencedRelation: "trips"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "trip_stops_trip_id_fkey"
      columns: ["trip_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["id"]
    }
                  ]
                },"trips": {
                  Row: {
                    "allows_pets": boolean,"allows_smoking": boolean,"booking_mode": Database["public"]['Enums']["booking_mode"],"cancel_reason": string | null,"cancelled_at": string | null,"completed_ask_at": string | null,"completed_at": string | null,"created_at": string,"currency": string,"departed_at": string | null,"departure_at": string,"destination_detail": string | null,"destination_place_id": string,"driver_arrived_at": string | null,"driver_confirmed_at": string | null,"driver_id": string,"id": string,"luggage": Database["public"]['Enums']["luggage_size"],"max_two_in_back": boolean,"notes": string | null,"origin_detail": string | null,"origin_place_id": string,"price_per_seat_kz": number,"published_at": string | null,"reminded_24h_at": string | null,"reminded_6h_at": string | null,"seats_available": number,"seats_offered": number,"status": Database["public"]['Enums']["trip_status"],"updated_at": string,"vehicle_id": string,"view_count": number,"wait_minutes": number
                  }
                  ComputedFields: never
                  Insert: {
                    "allows_pets"?: boolean,"allows_smoking"?: boolean,"booking_mode"?: Database["public"]['Enums']["booking_mode"],"cancel_reason"?: string | null,"cancelled_at"?: string | null,"completed_ask_at"?: string | null,"completed_at"?: string | null,"created_at"?: string,"currency"?: string,"departed_at"?: string | null,"departure_at": string,"destination_detail"?: string | null,"destination_place_id": string,"driver_arrived_at"?: string | null,"driver_confirmed_at"?: string | null,"driver_id": string,"id"?: string,"luggage"?: Database["public"]['Enums']["luggage_size"],"max_two_in_back"?: boolean,"notes"?: string | null,"origin_detail"?: string | null,"origin_place_id": string,"price_per_seat_kz": number,"published_at"?: string | null,"reminded_24h_at"?: string | null,"reminded_6h_at"?: string | null,"seats_available": number,"seats_offered": number,"status"?: Database["public"]['Enums']["trip_status"],"updated_at"?: string,"vehicle_id": string,"view_count"?: number,"wait_minutes"?: number
                  }
                  Update: {
                    "allows_pets"?: boolean,"allows_smoking"?: boolean,"booking_mode"?: Database["public"]['Enums']["booking_mode"],"cancel_reason"?: string | null,"cancelled_at"?: string | null,"completed_ask_at"?: string | null,"completed_at"?: string | null,"created_at"?: string,"currency"?: string,"departed_at"?: string | null,"departure_at"?: string,"destination_detail"?: string | null,"destination_place_id"?: string,"driver_arrived_at"?: string | null,"driver_confirmed_at"?: string | null,"driver_id"?: string,"id"?: string,"luggage"?: Database["public"]['Enums']["luggage_size"],"max_two_in_back"?: boolean,"notes"?: string | null,"origin_detail"?: string | null,"origin_place_id"?: string,"price_per_seat_kz"?: number,"published_at"?: string | null,"reminded_24h_at"?: string | null,"reminded_6h_at"?: string | null,"seats_available"?: number,"seats_offered"?: number,"status"?: Database["public"]['Enums']["trip_status"],"updated_at"?: string,"vehicle_id"?: string,"view_count"?: number,"wait_minutes"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "trips_destination_place_id_fkey"
      columns: ["destination_place_id"]
isOneToOne: false
      referencedRelation: "places"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "trips_destination_place_id_fkey"
      columns: ["destination_place_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["destination_place_id"]
    },{
      foreignKeyName: "trips_destination_place_id_fkey"
      columns: ["destination_place_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["origin_place_id"]
    },{
      foreignKeyName: "trips_driver_id_fkey"
      columns: ["driver_id"]
isOneToOne: false
      referencedRelation: "driver_wallet"
      referencedColumns: ["user_id"]
    },{
      foreignKeyName: "trips_driver_id_fkey"
      columns: ["driver_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "trips_driver_id_fkey"
      columns: ["driver_id"]
isOneToOne: false
      referencedRelation: "profiles_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "trips_driver_id_fkey"
      columns: ["driver_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["driver_id"]
    },{
      foreignKeyName: "trips_origin_place_id_fkey"
      columns: ["origin_place_id"]
isOneToOne: false
      referencedRelation: "places"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "trips_origin_place_id_fkey"
      columns: ["origin_place_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["destination_place_id"]
    },{
      foreignKeyName: "trips_origin_place_id_fkey"
      columns: ["origin_place_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["origin_place_id"]
    },{
      foreignKeyName: "trips_vehicle_id_fkey"
      columns: ["vehicle_id"]
isOneToOne: false
      referencedRelation: "vehicles"
      referencedColumns: ["id"]
    }
                  ]
                },"vehicles": {
                  Row: {
                    "color": string | null,"created_at": string,"id": string,"make": string,"model": string,"owner_id": string,"photo_url": string | null,"plate": string | null,"seats_total": number,"status": Database["public"]['Enums']["vehicle_status"],"updated_at": string,"verified": boolean,"year": number | null
                  }
                  ComputedFields: never
                  Insert: {
                    "color"?: string | null,"created_at"?: string,"id"?: string,"make": string,"model": string,"owner_id": string,"photo_url"?: string | null,"plate"?: string | null,"seats_total": number,"status"?: Database["public"]['Enums']["vehicle_status"],"updated_at"?: string,"verified"?: boolean,"year"?: number | null
                  }
                  Update: {
                    "color"?: string | null,"created_at"?: string,"id"?: string,"make"?: string,"model"?: string,"owner_id"?: string,"photo_url"?: string | null,"plate"?: string | null,"seats_total"?: number,"status"?: Database["public"]['Enums']["vehicle_status"],"updated_at"?: string,"verified"?: boolean,"year"?: number | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "vehicles_owner_id_fkey"
      columns: ["owner_id"]
isOneToOne: false
      referencedRelation: "driver_wallet"
      referencedColumns: ["user_id"]
    },{
      foreignKeyName: "vehicles_owner_id_fkey"
      columns: ["owner_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "vehicles_owner_id_fkey"
      columns: ["owner_id"]
isOneToOne: false
      referencedRelation: "profiles_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "vehicles_owner_id_fkey"
      columns: ["owner_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["driver_id"]
    }
                  ]
                }
          }
          Views: {
            "driver_wallet": {
                  Row: {
                    "balance_kz": number,"earned_total_kz": number | null,"payout_method": Json | null,"payouts_pending_kz": number | null,"pending_kz": number | null,"user_id": string
                  }
                  ComputedFields: never
                  Insert: {
                           "balance_kz"?: number | null,"earned_total_kz"?: never,"payout_method"?: Json | null,"payouts_pending_kz"?: never,"pending_kz"?: never,"user_id"?: string | null
                         }
                        Update: {
                           "balance_kz"?: number | null,"earned_total_kz"?: never,"payout_method"?: Json | null,"payouts_pending_kz"?: never,"pending_kz"?: never,"user_id"?: string | null
                         }
                        Relationships: [
                    
                  ]
                },"my_bookings": {
                  Row: {
                    "booking_mode": Database["public"]['Enums']["booking_mode"],"cancel_reason": string | null,"cancelled_at": string | null,"cancelled_by": Database["public"]['Enums']["party"] | null,"completed_at": string | null,"conversation_id": string | null,"created_at": string,"departure_at": string,"destination_detail": string | null,"destination_name": string,"destination_slug": string,"driver_arrived_at": string | null,"driver_avatar_url": string | null,"driver_id": string,"driver_name": string,"fee_kz": number,"id": string,"message": string | null,"origin_detail": string | null,"origin_name": string,"origin_slug": string,"paid_total_kz": number | null,"passenger_avatar_url": string | null,"passenger_cancels_total": number,"passenger_confirmed_at": string | null,"passenger_id": string,"passenger_name": string,"passenger_no_shows": number,"passenger_rating_avg": number,"passenger_rating_count": number,"passenger_trips_ridden": number,"payment_expires_at": string | null,"payment_status": Database["public"]['Enums']["payment_status"] | null,"pin_code": string | null,"pin_entered_at": string | null,"price_total_kz": number,"refund_kz": number,"requested_at": string | null,"responded_at": string | null,"seats": number,"status": Database["public"]['Enums']["booking_status"],"trip_id": string,"trip_status": Database["public"]['Enums']["trip_status"],"vehicle_color": string | null,"vehicle_make": string,"vehicle_model": string,"vehicle_photo_url": string | null,"vehicle_plate_suffix": string | null,"wait_minutes": number,"wait_until": string | null
                  }
                  ComputedFields: never
                  Relationships: [
                    {
      foreignKeyName: "bookings_passenger_id_fkey"
      columns: ["passenger_id"]
isOneToOne: false
      referencedRelation: "driver_wallet"
      referencedColumns: ["user_id"]
    },{
      foreignKeyName: "bookings_passenger_id_fkey"
      columns: ["passenger_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "bookings_passenger_id_fkey"
      columns: ["passenger_id"]
isOneToOne: false
      referencedRelation: "profiles_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "bookings_passenger_id_fkey"
      columns: ["passenger_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["driver_id"]
    },{
      foreignKeyName: "bookings_trip_id_fkey"
      columns: ["trip_id"]
isOneToOne: false
      referencedRelation: "trips"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "bookings_trip_id_fkey"
      columns: ["trip_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "trips_driver_id_fkey"
      columns: ["driver_id"]
isOneToOne: false
      referencedRelation: "driver_wallet"
      referencedColumns: ["user_id"]
    },{
      foreignKeyName: "trips_driver_id_fkey"
      columns: ["driver_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "trips_driver_id_fkey"
      columns: ["driver_id"]
isOneToOne: false
      referencedRelation: "profiles_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "trips_driver_id_fkey"
      columns: ["driver_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["driver_id"]
    }
                  ]
                },"my_conversations": {
                  Row: {
                    "booking_id": string | null,"closed_at": string | null,"departure_at": string,"destination_name": string,"driver_id": string,"id": string,"last_message_at": string | null,"last_message_body": string | null,"last_message_sender_id": string | null,"origin_name": string,"other_user_avatar_url": string | null,"other_user_id": string | null,"other_user_name": string,"passenger_id": string,"trip_id": string,"unread_count": number | null
                  }
                  ComputedFields: never
                  Relationships: [
                    {
      foreignKeyName: "conversations_booking_id_fkey"
      columns: ["booking_id"]
isOneToOne: false
      referencedRelation: "bookings"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "conversations_booking_id_fkey"
      columns: ["booking_id"]
isOneToOne: false
      referencedRelation: "my_bookings"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "conversations_driver_id_fkey"
      columns: ["driver_id"]
isOneToOne: false
      referencedRelation: "driver_wallet"
      referencedColumns: ["user_id"]
    },{
      foreignKeyName: "conversations_driver_id_fkey"
      columns: ["driver_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "conversations_driver_id_fkey"
      columns: ["driver_id"]
isOneToOne: false
      referencedRelation: "profiles_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "conversations_driver_id_fkey"
      columns: ["driver_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["driver_id"]
    },{
      foreignKeyName: "conversations_passenger_id_fkey"
      columns: ["passenger_id"]
isOneToOne: false
      referencedRelation: "driver_wallet"
      referencedColumns: ["user_id"]
    },{
      foreignKeyName: "conversations_passenger_id_fkey"
      columns: ["passenger_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "conversations_passenger_id_fkey"
      columns: ["passenger_id"]
isOneToOne: false
      referencedRelation: "profiles_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "conversations_passenger_id_fkey"
      columns: ["passenger_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["driver_id"]
    },{
      foreignKeyName: "conversations_trip_id_fkey"
      columns: ["trip_id"]
isOneToOne: false
      referencedRelation: "trips"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "conversations_trip_id_fkey"
      columns: ["trip_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "messages_sender_id_fkey"
      columns: ["last_message_sender_id"]
isOneToOne: false
      referencedRelation: "driver_wallet"
      referencedColumns: ["user_id"]
    },{
      foreignKeyName: "messages_sender_id_fkey"
      columns: ["last_message_sender_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "messages_sender_id_fkey"
      columns: ["last_message_sender_id"]
isOneToOne: false
      referencedRelation: "profiles_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "messages_sender_id_fkey"
      columns: ["last_message_sender_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["driver_id"]
    }
                  ]
                },"pending_refunds": {
                  Row: {
                    "amount_kz": number,"booking_id": string,"payer_id": string,"payer_phone": string | null,"payment_id": string,"provider_ref": string | null,"refund_attempts": number,"refund_failed_at": string | null,"refund_kz": number,"updated_at": string
                  }
                  ComputedFields: never
                  Relationships: [
                    {
      foreignKeyName: "payments_booking_id_fkey"
      columns: ["booking_id"]
isOneToOne: false
      referencedRelation: "bookings"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "payments_booking_id_fkey"
      columns: ["booking_id"]
isOneToOne: false
      referencedRelation: "my_bookings"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "payments_payer_id_fkey"
      columns: ["payer_id"]
isOneToOne: false
      referencedRelation: "driver_wallet"
      referencedColumns: ["user_id"]
    },{
      foreignKeyName: "payments_payer_id_fkey"
      columns: ["payer_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "payments_payer_id_fkey"
      columns: ["payer_id"]
isOneToOne: false
      referencedRelation: "profiles_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "payments_payer_id_fkey"
      columns: ["payer_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["driver_id"]
    }
                  ]
                },"profiles_public": {
                  Row: {
                    "avatar_url": string | null,"bio": string | null,"birth_year": number | null,"cancel_badge": string | null,"cancels_total": number,"chat_level": Database["public"]['Enums']["chat_level"],"display_name": string,"driver_verified": boolean | null,"id": string,"member_since": string,"rating_avg": number,"rating_count": number,"trips_driven": number,"trips_ridden": number
                  }
                  ComputedFields: never
                  Insert: {
                           "avatar_url"?: string | null,"bio"?: string | null,"birth_year"?: number | null,"cancel_badge"?: never,"cancels_total"?: number | null,"chat_level"?: Database["public"]['Enums']["chat_level"] | null,"display_name"?: string | null,"driver_verified"?: never,"id"?: string | null,"member_since"?: string | null,"rating_avg"?: number | null,"rating_count"?: number | null,"trips_driven"?: number | null,"trips_ridden"?: number | null
                         }
                        Update: {
                           "avatar_url"?: string | null,"bio"?: string | null,"birth_year"?: number | null,"cancel_badge"?: never,"cancels_total"?: number | null,"chat_level"?: Database["public"]['Enums']["chat_level"] | null,"display_name"?: string | null,"driver_verified"?: never,"id"?: string | null,"member_since"?: string | null,"rating_avg"?: number | null,"rating_count"?: number | null,"trips_driven"?: number | null,"trips_ridden"?: number | null
                         }
                        Relationships: [
                    
                  ]
                },"reviews_public": {
                  Row: {
                    "author_avatar_url": string | null,"author_id": string,"author_name": string,"booking_id": string,"comment": string | null,"created_at": string,"direction": Database["public"]['Enums']["review_direction"],"id": string,"rating": number,"tags": (string)[],"target_id": string
                  }
                  ComputedFields: never
                  Relationships: [
                    {
      foreignKeyName: "reviews_author_id_fkey"
      columns: ["author_id"]
isOneToOne: false
      referencedRelation: "driver_wallet"
      referencedColumns: ["user_id"]
    },{
      foreignKeyName: "reviews_author_id_fkey"
      columns: ["author_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "reviews_author_id_fkey"
      columns: ["author_id"]
isOneToOne: false
      referencedRelation: "profiles_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "reviews_author_id_fkey"
      columns: ["author_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["driver_id"]
    },{
      foreignKeyName: "reviews_booking_id_fkey"
      columns: ["booking_id"]
isOneToOne: false
      referencedRelation: "bookings"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "reviews_booking_id_fkey"
      columns: ["booking_id"]
isOneToOne: false
      referencedRelation: "my_bookings"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "reviews_target_id_fkey"
      columns: ["target_id"]
isOneToOne: false
      referencedRelation: "driver_wallet"
      referencedColumns: ["user_id"]
    },{
      foreignKeyName: "reviews_target_id_fkey"
      columns: ["target_id"]
isOneToOne: false
      referencedRelation: "profiles"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "reviews_target_id_fkey"
      columns: ["target_id"]
isOneToOne: false
      referencedRelation: "profiles_public"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "reviews_target_id_fkey"
      columns: ["target_id"]
isOneToOne: false
      referencedRelation: "trips_public"
      referencedColumns: ["driver_id"]
    }
                  ]
                },"route_stats": {
                  Row: {
                    "destination_name": string,"destination_slug": string,"min_price_kz": number | null,"minutes": number | null,"next_departure_at": string | null,"origin_name": string,"origin_slug": string,"price_hint_kz": number | null,"refreshed_at": string | null,"trips_30d": number | null,"trips_upcoming": number | null
                  }
                  ComputedFields: never
                  Relationships: [
                    
                  ]
                },"trips_public": {
                  Row: {
                    "allows_pets": boolean,"allows_smoking": boolean,"booking_mode": Database["public"]['Enums']["booking_mode"],"currency": string,"departure_at": string,"destination_detail": string | null,"destination_name": string,"destination_place_id": string,"destination_province": string,"destination_slug": string,"driver_avatar_url": string | null,"driver_cancels_total": number,"driver_chat_level": Database["public"]['Enums']["chat_level"],"driver_id": string,"driver_name": string,"driver_rating_avg": number,"driver_rating_count": number,"driver_trips_driven": number,"driver_verified": boolean | null,"duration_minutes": number | null,"id": string,"luggage": Database["public"]['Enums']["luggage_size"],"max_two_in_back": boolean,"notes": string | null,"origin_detail": string | null,"origin_name": string,"origin_place_id": string,"origin_province": string,"origin_slug": string,"price_per_seat_kz": number,"published_at": string | null,"seats_available": number,"seats_offered": number,"status": Database["public"]['Enums']["trip_status"],"vehicle_color": string | null,"vehicle_make": string,"vehicle_model": string,"vehicle_photo_url": string | null,"vehicle_verified": boolean,"wait_minutes": number
                  }
                  ComputedFields: never
                  Relationships: [
                    
                  ]
                }
          }
          Functions: {
            "admin_can_see_conversation":
{ Args: { "c": Omit<Database["public"]['Tables']["conversations"]['Row'], Database["public"]['Tables']["conversations"]['ComputedFields']> }; Returns: boolean
                           },
"admin_cancel_booking":
{ Args: { "booking_id": string,"reason": string }; Returns: Json
                           },
"admin_cancel_trip":
{ Args: { "reason": string,"trip_id": string }; Returns: Json
                           },
"admin_ledger_balances":
{ Args: Record<PropertyKey, never>; Returns: {
              "account": Database["public"]['Enums']["ledger_account"],"balance_kz": number,"entries": number
            }[]
                           },
"admin_mark_refund_manual":
{ Args: { "note"?: string,"payment_id": string,"ref": string }; Returns: Json
                           },
"admin_merge_places":
{ Args: { "from_id": string,"into_id": string }; Returns: undefined
                           },
"admin_moderate":
{ Args: { "action": Database["public"]['Enums']["mod_action"],"days"?: number,"reason": string,"report_id"?: string,"target_id": string }; Returns: undefined
                           },
"admin_refund_queue":
{ Args: Record<PropertyKey, never>; Returns: {
              "amount_kz": number,"booking_id": string,"is_manual": boolean,"payer_id": string,"payer_name": string,"payer_phone": string,"payment_id": string,"provider_ref": string,"refund_attempts": number,"refund_failed_at": string,"refund_kz": number,"updated_at": string
            }[]
                           },
"admin_resolve_report":
{ Args: { "note"?: string,"outcome": string,"report_id": string }; Returns: undefined
                           },
"admin_search_users":
{ Args: { "lim"?: number,"q": string }; Returns: Json[]
                           },
"admin_stats":
{ Args: Record<PropertyKey, never>; Returns: Json
                           },
"admin_upsert_place":
{ Args: { "payload": Json }; Returns: string
                           },
"admin_weekly":
{ Args: { "weeks"?: number }; Returns: Json[]
                           },
"before_user_created_hook":
{ Args: { "event": Json }; Returns: Json
                           },
"calc_fee_kz":
{ Args: { "price_total_kz": number }; Returns: number
                           },
"cancel_booking":
{ Args: { "booking_id": string,"reason"?: string }; Returns: Json
                           },
"cancel_booking_by_system":
{ Args: { "b": Omit<Database["public"]['Tables']["bookings"]['Row'], Database["public"]['Tables']["bookings"]['ComputedFields']>,"p_reason": string }; Returns: number
                           },
"cancel_quote":
{ Args: { "booking_id": string }; Returns: Json
                           },
"cancel_trip":
{ Args: { "reason"?: string,"trip_id": string }; Returns: undefined
                           },
"cancel_trip_cascade":
{ Args: { "p_by": Database["public"]['Enums']["party"],"p_reason": string,"t": Omit<Database["public"]['Tables']["trips"]['Row'], Database["public"]['Tables']["trips"]['ComputedFields']> }; Returns: Json
                           },
"complete_booking":
{ Args: { "b": Omit<Database["public"]['Tables']["bookings"]['Row'], Database["public"]['Tables']["bookings"]['ComputedFields']>,"p_by": Database["public"]['Enums']["party"] }; Returns: undefined
                           },
"confirm_payment":
{ Args: { "new_status": string,"payer_phone": string,"payment_id": string,"provider_ref": string,"raw"?: Json }; Returns: undefined
                           },
"confirm_trip":
{ Args: { "booking_id": string,"happened": boolean }; Returns: undefined
                           },
"confirm_trip_intent":
{ Args: { "trip_id": string }; Returns: undefined
                           },
"conversation_paid":
{ Args: { "c": Omit<Database["public"]['Tables']["conversations"]['Row'], Database["public"]['Tables']["conversations"]['ComputedFields']> }; Returns: boolean
                           },
"create_return_trip":
{ Args: { "departure_at": string,"trip_id": string }; Returns: string
                           },
"current_profile":
{ Args: Record<PropertyKey, never>; Returns: {
              "adult_confirmed_at": string | null,
"avatar_url": string | null,
"balance_kz": number,
"bio": string | null,
"birth_year": number | null,
"cancels_total": number,
"chat_level": Database["public"]['Enums']["chat_level"],
"created_at": string,
"display_name": string,
"driver_status": Database["public"]['Enums']["driver_status"],
"driver_verified_at": string | null,
"id": string,
"is_admin": boolean,
"last_seen_at": string | null,
"locale": string,
"no_shows": number,
"payout_method": Json | null,
"phone": string | null,
"phone_verified_at": string | null,
"rating_avg": number,
"rating_count": number,
"status": Database["public"]['Enums']["profile_status"],
"suspended_until": string | null,
"terms_accepted_at": string | null,
"trips_driven": number,
"trips_ridden": number,
"updated_at": string
            }
                          SetofOptions: {
        from: "*"
        to: "profiles"
        isOneToOne: true
        isSetofReturn: false
      } },
"custom_access_token_hook":
{ Args: { "event": Json }; Returns: Json
                           },
"delete_me":
{ Args: Record<PropertyKey, never>; Returns: undefined
                           },
"driver_arrived":
{ Args: { "trip_id": string }; Returns: Json
                           },
"driver_share_kz":
{ Args: { "b": Omit<Database["public"]['Tables']["bookings"]['Row'], Database["public"]['Tables']["bookings"]['ComputedFields']>,"p_amount_kz": number }; Returns: number
                           },
"edge_call":
{ Args: { "p_body"?: Json,"p_path": string }; Returns: number
                           },
"ensure_conversation":
{ Args: { "p_booking_id"?: string,"p_passenger_id": string,"p_trip_id": string }; Returns: string
                           },
"enter_pin":
{ Args: { "booking_id": string,"pin": string }; Returns: Json
                           },
"escrow_balance_kz":
{ Args: { "p_booking_id": string }; Returns: number
                           },
"forfeit_trip_holds":
{ Args: { "p_trip_id": string }; Returns: undefined
                           },
"gateway_fee_kz":
{ Args: { "p_amount_kz": number }; Returns: number
                           },
"gen_pin":
{ Args: Record<PropertyKey, never>; Returns: string
                           },
"is_admin":
{ Args: Record<PropertyKey, never>; Returns: boolean
                           },
"ledger_forfeit":
{ Args: { "b": Omit<Database["public"]['Tables']["bookings"]['Row'], Database["public"]['Tables']["bookings"]['ComputedFields']>,"p_amount_kz": number }; Returns: undefined
                           },
"ledger_payment":
{ Args: { "pay": Omit<Database["public"]['Tables']["payments"]['Row'], Database["public"]['Tables']["payments"]['ComputedFields']> }; Returns: undefined
                           },
"ledger_post":
{ Args: { "p_booking_id": string,"p_entries": Json,"p_memo": string,"p_op_id": string }; Returns: undefined
                           },
"ledger_refund":
{ Args: { "b": Omit<Database["public"]['Tables']["bookings"]['Row'], Database["public"]['Tables']["bookings"]['ComputedFields']>,"p_gateway_fee_kz"?: number,"p_refund_kz": number }; Returns: undefined
                           },
"ledger_release":
{ Args: { "b": Omit<Database["public"]['Tables']["bookings"]['Row'], Database["public"]['Tables']["bookings"]['ComputedFields']>,"p_amount_kz": number }; Returns: undefined
                           },
"log_event":
{ Args: { "name": string,"plat"?: Database["public"]['Enums']["platform"],"props"?: Json }; Returns: undefined
                           },
"mark_no_show":
{ Args: { "booking_id": string }; Returns: undefined
                           },
"mark_notifications_read":
{ Args: { "ids": (string)[] }; Returns: undefined
                           },
"mark_payout":
{ Args: { "new_status": string,"payout_id": string,"ref"?: string }; Returns: undefined
                           },
"mark_read":
{ Args: { "conversation_id": string,"up_to_message_id": number }; Returns: undefined
                           },
"mask_text":
{ Args: { "p_body": string }; Returns: string
                           },
"mod_log":
{ Args: { "p_action": Database["public"]['Enums']["mod_action"],"p_admin": string,"p_payload"?: Json,"p_reason": string,"p_report"?: string,"p_target": string,"p_until"?: string }; Returns: string
                           },
"notification_delivered":
{ Args: { "error"?: string,"id": string,"ok": boolean }; Returns: undefined
                           },
"notify":
{ Args: { "p_allow_sms"?: boolean,"p_payload"?: Json,"p_scheduled_for"?: string,"p_type": string,"p_user_id": string }; Returns: undefined
                           },
"notify_admins":
{ Args: { "p_payload": Json,"p_type": string }; Returns: undefined
                           },
"payment_initiated":
{ Args: { "payment_id": string,"provider_ref": string,"raw"?: Json }; Returns: Json
                           },
"payment_refund_result":
{ Args: { "ok": boolean,"payment_id": string,"raw"?: Json,"refund_ref"?: string }; Returns: Json
                           },
"pin_attempts_blocked":
{ Args: { "p_driver_id": string }; Returns: boolean
                           },
"price_hint":
{ Args: { "destination_place_id": string,"origin_place_id": string }; Returns: Json
                           },
"publish_trip":
{ Args: { "payload": Json }; Returns: Json
                           },
"raise_boleia":
{ Args: { "code": string }; Returns: undefined
                           },
"refund_rule":
{ Args: { "b": Omit<Database["public"]['Tables']["bookings"]['Row'], Database["public"]['Tables']["bookings"]['ComputedFields']>,"p_by": Database["public"]['Enums']["party"],"t": Omit<Database["public"]['Tables']["trips"]['Row'], Database["public"]['Tables']["trips"]['ComputedFields']> }; Returns: Json
                           },
"register_device":
{ Args: { "app_version"?: string,"device_platform": Database["public"]['Enums']["platform"],"token": string }; Returns: undefined
                           },
"report_user":
{ Args: { "booking_id"?: string,"details"?: string,"message_id"?: number,"reason": Database["public"]['Enums']["report_reason"],"target_id": string,"trip_id"?: string }; Returns: string
                           },
"request_booking":
{ Args: { "message"?: string,"seats": number,"trip_id": string }; Returns: Json
                           },
"request_payout":
{ Args: { "amount_kz": number }; Returns: string
                           },
"require_admin":
{ Args: Record<PropertyKey, never>; Returns: {
              "adult_confirmed_at": string | null,
"avatar_url": string | null,
"balance_kz": number,
"bio": string | null,
"birth_year": number | null,
"cancels_total": number,
"chat_level": Database["public"]['Enums']["chat_level"],
"created_at": string,
"display_name": string,
"driver_status": Database["public"]['Enums']["driver_status"],
"driver_verified_at": string | null,
"id": string,
"is_admin": boolean,
"last_seen_at": string | null,
"locale": string,
"no_shows": number,
"payout_method": Json | null,
"phone": string | null,
"phone_verified_at": string | null,
"rating_avg": number,
"rating_count": number,
"status": Database["public"]['Enums']["profile_status"],
"suspended_until": string | null,
"terms_accepted_at": string | null,
"trips_driven": number,
"trips_ridden": number,
"updated_at": string
            }
                          SetofOptions: {
        from: "*"
        to: "profiles"
        isOneToOne: true
        isSetofReturn: false
      } },
"resolve_dispute":
{ Args: { "amount_kz"?: number,"booking_id": string,"outcome": string }; Returns: undefined
                           },
"respond_booking":
{ Args: { "accept": boolean,"booking_id": string,"reason"?: string }; Returns: undefined
                           },
"retry_payment":
{ Args: { "booking_id": string }; Returns: Json
                           },
"reveal_contact":
{ Args: { "booking_id": string }; Returns: Json
                           },
"review_verification":
{ Args: { "approve": boolean,"reason"?: string,"verification_id": string }; Returns: undefined
                           },
"run_scheduler":
{ Args: { "as_of"?: string }; Returns: Json
                           },
"same_phone":
{ Args: { "a": string,"b": string }; Returns: boolean
                           },
"sch_ask_completed":
{ Args: { "as_of": string }; Returns: number
                           },
"sch_autocomplete":
{ Args: { "as_of": string }; Returns: number
                           },
"sch_cleanup":
{ Args: { "as_of": string }; Returns: number
                           },
"sch_close_chats":
{ Args: { "as_of": string }; Returns: number
                           },
"sch_depart_trips":
{ Args: { "as_of": string }; Returns: number
                           },
"sch_driver_no_show":
{ Args: { "as_of": string }; Returns: number
                           },
"sch_expire_payments":
{ Args: { "as_of": string }; Returns: number
                           },
"sch_expire_requests":
{ Args: { "as_of": string }; Returns: number
                           },
"sch_lift_suspensions":
{ Args: { "as_of": string }; Returns: number
                           },
"sch_reconcile":
{ Args: { "as_of": string }; Returns: number
                           },
"sch_refresh_route_stats":
{ Args: { "as_of": string }; Returns: number
                           },
"sch_remind_24h":
{ Args: { "as_of": string }; Returns: number
                           },
"sch_remind_6h":
{ Args: { "as_of": string }; Returns: number
                           },
"sch_review_visibility":
{ Args: { "as_of": string }; Returns: number
                           },
"sch_send_pins":
{ Args: { "as_of": string }; Returns: number
                           },
"scheduler_step":
{ Args: { "as_of": string,"p_every"?: string,"p_name": string }; Returns: Json
                           },
"search_trips":
{ Args: { "cursor_departure"?: string,"cursor_id"?: string,"destination_slug": string,"origin_slug": string,"page_size"?: number,"seats"?: number,"travel_date": string }; Returns: {
              "allows_pets": boolean,
"allows_smoking": boolean,
"booking_mode": Database["public"]['Enums']["booking_mode"],
"currency": string,
"departure_at": string,
"destination_detail": string | null,
"destination_name": string,
"destination_place_id": string,
"destination_province": string,
"destination_slug": string,
"driver_avatar_url": string | null,
"driver_cancels_total": number,
"driver_chat_level": Database["public"]['Enums']["chat_level"],
"driver_id": string,
"driver_name": string,
"driver_rating_avg": number,
"driver_rating_count": number,
"driver_trips_driven": number,
"driver_verified": boolean | null,
"duration_minutes": number | null,
"id": string,
"luggage": Database["public"]['Enums']["luggage_size"],
"max_two_in_back": boolean,
"notes": string | null,
"origin_detail": string | null,
"origin_name": string,
"origin_place_id": string,
"origin_province": string,
"origin_slug": string,
"price_per_seat_kz": number,
"published_at": string | null,
"seats_available": number,
"seats_offered": number,
"status": Database["public"]['Enums']["trip_status"],
"vehicle_color": string | null,
"vehicle_make": string,
"vehicle_model": string,
"vehicle_photo_url": string | null,
"vehicle_verified": boolean,
"wait_minutes": number
            }[]
                          SetofOptions: {
        from: "*"
        to: "trips_public"
        isOneToOne: false
        isSetofReturn: true
      } },
"send_message":
{ Args: { "body": string,"conversation_id"?: string,"trip_id"?: string }; Returns: number
                           },
"settle_trip":
{ Args: { "p_trip_id": string }; Returns: undefined
                           },
"show_limit":
{ Args: Record<PropertyKey, never>; Returns: number
                           },
"show_trgm":
{ Args: { "": string }; Returns: (string)[]
                           },
"submit_review":
{ Args: { "booking_id": string,"comment"?: string,"rating": number,"tags"?: (string)[] }; Returns: string
                           },
"submit_verification":
{ Args: { "doc_urls": Json,"vehicle_id": string }; Returns: string
                           },
"system_message":
{ Args: { "p_body": string,"p_conversation_id": string }; Returns: undefined
                           },
"trip_for_driver":
{ Args: { "p_trip_id": string }; Returns: {
              "allows_pets": boolean,
"allows_smoking": boolean,
"booking_mode": Database["public"]['Enums']["booking_mode"],
"cancel_reason": string | null,
"cancelled_at": string | null,
"completed_ask_at": string | null,
"completed_at": string | null,
"created_at": string,
"currency": string,
"departed_at": string | null,
"departure_at": string,
"destination_detail": string | null,
"destination_place_id": string,
"driver_arrived_at": string | null,
"driver_confirmed_at": string | null,
"driver_id": string,
"id": string,
"luggage": Database["public"]['Enums']["luggage_size"],
"max_two_in_back": boolean,
"notes": string | null,
"origin_detail": string | null,
"origin_place_id": string,
"price_per_seat_kz": number,
"published_at": string | null,
"reminded_24h_at": string | null,
"reminded_6h_at": string | null,
"seats_available": number,
"seats_offered": number,
"status": Database["public"]['Enums']["trip_status"],
"updated_at": string,
"vehicle_id": string,
"view_count": number,
"wait_minutes": number
            }
                          SetofOptions: {
        from: "*"
        to: "trips"
        isOneToOne: true
        isSetofReturn: false
      } },
"update_trip":
{ Args: { "payload": Json,"trip_id": string }; Returns: undefined
                           },
"upsert_profile":
{ Args: { "payload": Json }; Returns: {
              "adult_confirmed_at": string | null,
"avatar_url": string | null,
"balance_kz": number,
"bio": string | null,
"birth_year": number | null,
"cancels_total": number,
"chat_level": Database["public"]['Enums']["chat_level"],
"created_at": string,
"display_name": string,
"driver_status": Database["public"]['Enums']["driver_status"],
"driver_verified_at": string | null,
"id": string,
"is_admin": boolean,
"last_seen_at": string | null,
"locale": string,
"no_shows": number,
"payout_method": Json | null,
"phone": string | null,
"phone_verified_at": string | null,
"rating_avg": number,
"rating_count": number,
"status": Database["public"]['Enums']["profile_status"],
"suspended_until": string | null,
"terms_accepted_at": string | null,
"trips_driven": number,
"trips_ridden": number,
"updated_at": string
            }
                          SetofOptions: {
        from: "*"
        to: "profiles"
        isOneToOne: true
        isSetofReturn: false
      } },
"upsert_vehicle":
{ Args: { "payload": Json }; Returns: string
                           }
          }
          Enums: {
            "booking_mode": "instant"|"approval","booking_status": "pending_payment"|"payment_failed"|"requested"|"accepted"|"declined"|"expired"|"cancelled"|"awaiting_confirm"|"completed"|"no_show"|"disputed","chat_level": "bla"|"blabla"|"blablabla","driver_status": "none"|"pending"|"verified"|"rejected","ledger_account": "passenger_escrow"|"driver_balance"|"platform_fee"|"refunds"|"gateway_fees"|"cash_out"|"cash_in","luggage_size": "small"|"medium"|"large","mod_action": "warn"|"restrict"|"suspend"|"ban"|"unban"|"verify_id"|"resolve_dispute"|"hide_trip"|"cancel_booking"|"manual_refund"|"report_dismissed","notif_channel": "push"|"sms"|"inapp","notif_status": "queued"|"sent"|"failed"|"read","party": "passenger"|"driver"|"system","payment_status": "created"|"pending"|"paid"|"failed"|"expired"|"refunded"|"partially_refunded","payout_status": "requested"|"processing"|"paid"|"failed"|"cancelled","place_kind": "city"|"town"|"landmark","platform": "ios"|"android"|"web","profile_status": "active"|"restricted"|"suspended"|"banned"|"deleted","report_reason": "no_show"|"unsafe_driving"|"harassment"|"scam"|"cash_offer"|"wrong_price"|"other","report_status": "open"|"reviewed"|"actioned"|"dismissed","review_direction": "passenger_to_driver"|"driver_to_passenger","trip_status": "draft"|"published"|"full"|"departed"|"completed"|"cancelled"|"expired","vehicle_status": "active"|"removed","verification_status": "pending"|"approved"|"rejected"
          }
          CompositeTypes: {
            [_ in never]: never
          }
        }
}

type DatabaseWithoutInternals = Omit<Database, '__InternalSupabase'>

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
  ? (DefaultSchema["Tables"] & DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
      Row: infer R
    }
    ? R
    : never
  : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
  ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
      Insert: infer I
    }
    ? I
    : never
  : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
  ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
      Update: infer U
    }
    ? U
    : never
  : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never
> = DefaultSchemaEnumNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
  ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
  : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never
> = PublicCompositeTypeNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
  ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
  : never

export const Constants = {
  "graphql_public": {
          Enums: {
            
          }
        },"public": {
          Enums: {
            "booking_mode": ["instant", "approval"],"booking_status": ["pending_payment", "payment_failed", "requested", "accepted", "declined", "expired", "cancelled", "awaiting_confirm", "completed", "no_show", "disputed"],"chat_level": ["bla", "blabla", "blablabla"],"driver_status": ["none", "pending", "verified", "rejected"],"ledger_account": ["passenger_escrow", "driver_balance", "platform_fee", "refunds", "gateway_fees", "cash_out", "cash_in"],"luggage_size": ["small", "medium", "large"],"mod_action": ["warn", "restrict", "suspend", "ban", "unban", "verify_id", "resolve_dispute", "hide_trip", "cancel_booking", "manual_refund", "report_dismissed"],"notif_channel": ["push", "sms", "inapp"],"notif_status": ["queued", "sent", "failed", "read"],"party": ["passenger", "driver", "system"],"payment_status": ["created", "pending", "paid", "failed", "expired", "refunded", "partially_refunded"],"payout_status": ["requested", "processing", "paid", "failed", "cancelled"],"place_kind": ["city", "town", "landmark"],"platform": ["ios", "android", "web"],"profile_status": ["active", "restricted", "suspended", "banned", "deleted"],"report_reason": ["no_show", "unsafe_driving", "harassment", "scam", "cash_offer", "wrong_price", "other"],"report_status": ["open", "reviewed", "actioned", "dismissed"],"review_direction": ["passenger_to_driver", "driver_to_passenger"],"trip_status": ["draft", "published", "full", "departed", "completed", "cancelled", "expired"],"vehicle_status": ["active", "removed"],"verification_status": ["pending", "approved", "rejected"]
          }
        }
} as const
