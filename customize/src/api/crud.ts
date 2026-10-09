import { apiClient } from "@/lib/api-client";

/**
 * Generic CRUD factory bound to an edge-api resource path.
 *
 * edge-api is verb-in-path with ids-in-body (NOT REST): the mutating routes are
 * `POST /api/<resource>/create|edit|delete` and the id(s) travel in the request
 * body — delete included (edge-api convention: every mutation is a POST). Reads
 * are `GET /api/<resource>` (list) and `GET /api/<resource>/:id` (one).
 *
 * Callers build the full body (FK ids camelCase like `idEnterprise`; domain
 * attributes snake_case like `nm_site`, `week_begin` — matching the edge-api
 * input DTOs exactly, so NestJS ValidationPipe doesn't silently drop fields).
 * The CS-Admin `?idEnterprise=` tenant target is attached by the api-client
 * interceptor, not here.
 */
export function createCrud<T>(resource: string) {
  return {
    list: (params?: Record<string, unknown>) =>
      apiClient.get<T[]>(`/api/${resource}`, { params }).then((r) => r.data),
    get: (id: number | string) =>
      apiClient.get<T>(`/api/${resource}/${id}`).then((r) => r.data),
    create: (body: Record<string, unknown>) =>
      apiClient.post<T>(`/api/${resource}/create`, body).then((r) => r.data),
    edit: (body: Record<string, unknown>) =>
      apiClient.post<T>(`/api/${resource}/edit`, body).then((r) => r.data),
    remove: (body: Record<string, unknown>) =>
      apiClient.post<void>(`/api/${resource}/delete`, body).then((r) => r.data),
  };
}
