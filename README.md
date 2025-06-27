`sh -ci "$(curl -fsSL https://internetcomputer.org/install.sh)"`

`npm i -g pnpm ic-mops`

`pnpm i`

`mops i`

`modify file dfx.json - canisters.guarantee.controllers`

`dfx start --background`

`pnpm deploy:local`

`pnpm test:guarantee`
