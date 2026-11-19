# Knot

Knot gets a thought out of your head and into a note with as little friction as the device allows. You type it, say it, or write it by hand, on a Mac, iPhone, iPad or Apple Watch. Every capture lands in one stream.

Knot is being rebuilt from an empty repository. There is no app to build here yet.

## Where things are

- [docs/product-spec.md](docs/product-spec.md): what Knot v1 does.
- [docs/architecture.md](docs/architecture.md): how it is built.
- [docs/design/brief.md](docs/design/brief.md): the brief for the design round.
- [PLAN.md](PLAN.md): how the work is split, ordered, checked and merged.
- [TODOS.md](TODOS.md): what was deferred from v1.
- [AGENTS.md](AGENTS.md): rules for coding agents working here.
- [Resources/Brand/](Resources/Brand/): the icon and the mark, carried over from the earlier app.

## The earlier app

Until November 2026 this repository held a different app with the same name: a capture tool for Obsidian vaults on macOS, released as 0.1.0 and 0.2.0. It is retired. Nothing of it remains on `main` except the name, the icon and the mark.

Its code is kept:

- The tags `v0.1.0` and `v0.2.0`, with their GitHub releases.
- The branch `archive/main-before-restart-2026-11-18`. It holds `main` as it was before the restart, plus the files that sat in the working folders and were never committed.
- The branches `archive/main-before-rewrite-2026-09-08` and `archive/pre-rewrite-2026-09-08`, from an earlier rewrite.

The new Knot does not read the earlier app's data, and it has no Obsidian integration.

## Licence

Knot is free software under the GNU General Public License, version 3 or, at your option, any later version. See [LICENSE](LICENSE).

It carries one additional permission, for distribution through app stores. See [LICENSE-APPSTORE.md](LICENSE-APPSTORE.md).

The earlier app was published under version 2 of the GPL. Its tags and archive branches keep the licence they were published under.

## Contributing

> Draft for Paolo's approval.

Knot is built for one person to begin with, by a team of coding agents that works from [PLAN.md](PLAN.md). A pull request from outside is welcome, and it is read before it is built or merged.

By submitting a contribution you agree that it is licensed on the same terms as Knot: GPL-3.0-or-later, with the additional permission in [LICENSE-APPSTORE.md](LICENSE-APPSTORE.md). You keep the copyright in your contribution. That permission is what lets a build that contains your code be distributed through the App Store.
