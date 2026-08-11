import { defineCollection, z } from "astro:content";

// News posts. Write one Markdown file per post in src/content/news/.
// The frontmatter block at the top of each file must match this shape.
const news = defineCollection({
  type: "content",
  schema: z.object({
    title: z.string(),
    date: z.date(),                    // YYYY-MM-DD
    summary: z.string(),               // the card blurb
    author: z.string().default("Sonny"),
    tag: z.string().optional(),        // e.g. "water", "council", "notice"
    draft: z.boolean().default(false), // true = hidden from the feed
  }),
});

export const collections = { news };
