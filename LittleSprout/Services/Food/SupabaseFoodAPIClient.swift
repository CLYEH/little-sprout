import Foundation
import Supabase

/// `FoodAPIClient` 的 Supabase 實作。方法 ↔ 後端對照見協定檔的文件註解。
final class SupabaseFoodAPIClient: FoodAPIClient {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    /// 只挑畫面用得到的欄位（不含 `active`）；`active = false` 的品項（日後下架用）不進圖鑑，
    /// 計數句的分母也就不含它們。
    func listFoodCatalog() async throws -> [FoodCatalogItem] {
        do {
            let response: PostgrestResponse<[FoodCatalogItem]> = try await client
                .from("food_catalog")
                .select("id,name_zh,category,sort_order,allergens,min_age_months")
                .eq("active", value: true)
                .order("sort_order", ascending: true)
                .execute()
            return response.value
        } catch {
            throw AppError.map(error)
        }
    }

    func listChildFoodRecords(childID: UUID) async throws -> [ChildFoodRecord] {
        do {
            let response: PostgrestResponse<[ChildFoodRecord]> = try await client
                .rpc("list_child_food_records", params: ["p_child_id": childID])
                .execute()
            return response.value
        } catch {
            throw AppError.map(error)
        }
    }
}
