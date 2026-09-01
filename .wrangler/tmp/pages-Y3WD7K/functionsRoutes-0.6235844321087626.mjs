import { onRequestGet as __api_attachment_ts_onRequestGet } from "/Users/relative/site/functions/api/attachment.ts"
import { onRequestPost as __api_upload_ts_onRequestPost } from "/Users/relative/site/functions/api/upload.ts"

export const routes = [
    {
      routePath: "/api/attachment",
      mountPath: "/api",
      method: "GET",
      middlewares: [],
      modules: [__api_attachment_ts_onRequestGet],
    },
  {
      routePath: "/api/upload",
      mountPath: "/api",
      method: "POST",
      middlewares: [],
      modules: [__api_upload_ts_onRequestPost],
    },
  ]