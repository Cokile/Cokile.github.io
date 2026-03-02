---
layout: page
title: Cokile's blog
---

<style>
  .site-header {
    display: none;
  }
</style>

<ul>
  {% assign posts_pages = site.pages | where_exp: "p", "p.path contains 'published/' and p.name == 'index.md'" %}
  {% assign sorted_pages = posts_pages | sort: "date" | reverse %}
  {% for p in sorted_pages %}
    <li>
      <a href="{{ p.url | relative_url }}">{{ p.title | default: p.url }}</a>
    </li>
  {% endfor %}
</ul>
