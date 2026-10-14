<template>
	<div
		v-if="accounts.length === 0"
		class="flex flex-col gap-3 bg-button-bg border border-solid border-surface-5 rounded-xl p-3 mt-2"
	>
		<span>{{ formatMessage(messages.notSignedIn) }}</span>
		<Button type="colored" color="brand" :disabled="loginDisabled" @click="login()">
			<LogInIcon v-if="!loginDisabled" />
			<SpinnerIcon v-else class="animate-spin" />
			{{ formatMessage(messages.signInToMinecraft) }}
		</Button>
		<Button :disabled="loginDisabled" @click="openOfflineModal()">
			{{ formatMessage(messages.playOffline) }}
		</Button>
	</div>
	<Accordion
		v-else
		class="w-full mt-2 bg-button-bg border border-solid border-surface-5 rounded-xl overflow-clip"
		button-class="button-base w-full bg-transparent px-3 py-2 border-0 cursor-pointer"
		:open-by-default="false"
	>
		<template #title>
			<div class="flex gap-2 w-full min-w-0">
				<Avatar
					size="36px"
					:src="
						selectedAccount
							? avatarUrl
							: 'https://launcher-files.modrinth.com/assets/steve_head.png'
					"
				/>
				<div class="flex flex-col items-start w-full min-w-0">
					<span class="truncate w-full text-left">{{
						selectedAccount ? selectedAccount.profile.name : formatMessage(messages.selectAccount)
					}}</span>
					<span class="text-secondary text-xs">{{ formatMessage(messages.minecraftAccount) }}</span>
				</div>
			</div>
		</template>
		<div class="bg-button-bg pt-1 pb-2 border-0 border-t border-solid border-surface-5">
			<template v-if="accounts.length > 0">
				<div v-for="account in accounts" :key="account.profile.id" class="flex gap-1 items-center">
					<button
						class="flex items-center flex-shrink flex-grow overflow-clip gap-2 p-2 border-0 bg-transparent cursor-pointer button-base min-w-0"
						@click="setAccount(account)"
					>
						<RadioButtonCheckedIcon
							v-if="selectedAccount && selectedAccount.profile.id === account.profile.id"
							class="w-5 h-5 text-brand shrink-0"
						/>
						<RadioButtonIcon v-else class="w-5 h-5 text-secondary shrink-0" />
						<Avatar :src="getAccountAvatarUrl(account)" size="24px" />
						<p
							class="m-0 truncate min-w-0"
							:class="
								selectedAccount && selectedAccount.profile.id === account.profile.id
									? 'text-contrast font-semibold'
									: 'text-primary'
							"
						>
							{{ account.profile.name }}
						</p>
						<span
							v-if="account.account_type === 'offline'"
							class="shrink-0 rounded-full bg-surface-5 px-2 py-0.5 text-xs text-secondary"
						>
							{{ formatMessage(messages.offlineBadge) }}
						</span>
					</button>
					<IconButton
						v-if="account.account_type === 'offline'"
						v-tooltip="formatMessage(messages.renameAccount)"
						type="quiet"
						:label="formatMessage(messages.renameAccount)"
						class="mr-1 !bg-button-bg !text-primary ![box-shadow:var(--shadow-button)]"
						@click="openOfflineModal(account)"
					>
						<EditIcon />
					</IconButton>
					<IconButton
						v-tooltip="formatMessage(messages.removeAccount)"
						type="quiet"
						color="red"
						:label="formatMessage(messages.removeAccount)"
						class="mr-2 !bg-button-bg !text-primary ![box-shadow:var(--shadow-button)] hover:!bg-red focus-visible:!bg-red hover:!text-[var(--color-accent-contrast)] focus-visible:!text-[var(--color-accent-contrast)]"
						@click="logout(account.profile.id)"
					>
						<TrashIcon />
					</IconButton>
				</div>
			</template>
			<div class="flex flex-col gap-2 px-2 pt-2">
				<Button
					v-if="accounts.length > 0"
					class="w-full !bg-button-bg !text-primary ![box-shadow:var(--shadow-button)]"
					:disabled="loginDisabled"
					@click="login()"
				>
					<PlusIcon />
					{{ formatMessage(messages.addAccount) }}
				</Button>
				<Button
					v-if="accounts.length > 0"
					class="w-full !bg-button-bg !text-primary ![box-shadow:var(--shadow-button)]"
					:disabled="loginDisabled"
					@click="openOfflineModal()"
				>
					<PlusIcon />
					{{ formatMessage(messages.playOffline) }}
				</Button>
			</div>
		</div>
	</Accordion>
	<NewModal
		ref="offlineModal"
		:header="
			renameTarget
				? formatMessage(messages.renameOfflineHeader)
				: formatMessage(messages.createOfflineHeader)
		"
		max-width="420px"
	>
		<div class="flex flex-col gap-3">
			<div class="labeled_input w-full">
				<p class="text-contrast font-semibold">{{ formatMessage(messages.offlineNameLabel) }}</p>
				<Input
					v-model="offlineName"
					type="text"
					:placeholder="formatMessage(messages.offlineNamePlaceholder)"
					clearable
					wrapper-class="w-full"
					@keydown.enter="submitOfflineModal"
				/>
			</div>
			<p v-if="offlineError" class="m-0 text-sm text-red">
				{{ offlineError }}
			</p>
			<p v-if="renameTarget" class="m-0 text-sm text-secondary">
				{{ formatMessage(messages.renameOfflineNote) }}
			</p>
			<div class="flex gap-2">
				<Button class="flex-1" @click="offlineModal?.hide()">
					{{ formatMessage(messages.cancel) }}
				</Button>
				<Button
					type="colored"
					color="brand"
					class="flex-1"
					:disabled="!isOfflineNameValid || offlineSaving"
					@click="submitOfflineModal"
				>
					<SpinnerIcon v-if="offlineSaving" class="animate-spin" />
					{{ renameTarget ? formatMessage(messages.rename) : formatMessage(messages.create) }}
				</Button>
			</div>
		</div>
	</NewModal>
</template>

<script setup lang="ts">
import {
	EditIcon,
	LogInIcon,
	PlusIcon,
	RadioButtonCheckedIcon,
	RadioButtonIcon,
	SpinnerIcon,
	TrashIcon,
} from '@modrinth/assets'
import {
	Accordion,
	Avatar,
	Button,
	defineMessages,
	IconButton,
	injectNotificationManager,
	Input,
	NewModal,
	useVIntl,
} from '@modrinth/ui'
import type { Ref } from 'vue'
import { computed, onUnmounted, ref } from 'vue'

import { useAppEvent } from '@/composables/use-app-event'
import { handleSevereError } from '@/composables/use-error.js'
import { trackEvent } from '@/helpers/analytics'
import {
	create_offline_user,
	get_default_user,
	login as login_flow,
	remove_user,
	rename_offline_user,
	set_default_user,
	users,
} from '@/helpers/auth'
import { getPlayerHeadUrl } from '@/helpers/rendering/player-head'
import type { Skin } from '@/helpers/skins'
import { get_available_skins } from '@/helpers/skins'

const { formatMessage } = useVIntl()
const { handleError } = injectNotificationManager()

const emit = defineEmits<{
	change: []
}>()

type MinecraftCredential = {
	account_type?: 'microsoft' | 'offline'
	profile: {
		id: string
		name: string
	}
}

const STEVE_HEAD_URL = 'https://launcher-files.modrinth.com/assets/steve_head.png'
const OFFLINE_NAME_PATTERN = /^[A-Za-z0-9_]{3,16}$/

const accounts: Ref<MinecraftCredential[]> = ref([])
const loginDisabled = ref(false)
const defaultUser = ref<string | undefined>()
const equippedSkin = ref<Skin | null>(null)
const equippedHeadUrl = ref<string>()
const offlineModal = ref<InstanceType<typeof NewModal>>()
const offlineName = ref('')
const offlineError = ref('')
const offlineSaving = ref(false)
const renameTarget = ref<MinecraftCredential | null>(null)
let headRequest = 0

async function updateHeadUrl(skin: Skin | null) {
	const request = ++headRequest
	if (equippedHeadUrl.value) URL.revokeObjectURL(equippedHeadUrl.value)
	equippedHeadUrl.value = undefined
	if (!skin) return
	const url = await getPlayerHeadUrl(skin)
	if (request !== headRequest) URL.revokeObjectURL(url)
	else equippedHeadUrl.value = url
}

onUnmounted(() => {
	headRequest++
	if (equippedHeadUrl.value) URL.revokeObjectURL(equippedHeadUrl.value)
})

async function refreshValues() {
	defaultUser.value = await get_default_user().catch(handleError)
	const userList = await users().catch(handleError)
	accounts.value = Array.isArray(userList) ? [...userList] : []
	accounts.value.sort((a, b) => (a.profile?.name ?? '').localeCompare(b.profile?.name ?? ''))

	try {
		const skins = await get_available_skins()
		equippedSkin.value = skins.find((skin) => skin.is_equipped) ?? null

		await updateHeadUrl(equippedSkin.value)
	} catch {
		equippedSkin.value = null
		void updateHeadUrl(null)
	}
}

async function setEquippedSkin(skin: Skin) {
	equippedSkin.value = skin

	try {
		await updateHeadUrl(skin)
	} catch (error) {
		console.warn('Failed to get head render for equipped skin:', error)
	}
}

function setLoginDisabled(value: boolean) {
	loginDisabled.value = value
}

defineExpose({
	refreshValues,
	setEquippedSkin,
	setLoginDisabled,
	login,
	loginDisabled,
	openOfflineModal,
})

await refreshValues()

const selectedAccount = computed(() =>
	accounts.value.find((account) => account.profile.id === defaultUser.value),
)

const avatarUrl = computed(() => {
	if (selectedAccount.value?.account_type === 'offline') {
		return STEVE_HEAD_URL
	}
	if (equippedSkin.value?.texture_key) {
		const cachedUrl = equippedHeadUrl.value
		if (cachedUrl) {
			return cachedUrl
		}
		return `https://mc-heads.net/avatar/${equippedSkin.value.texture_key}/128`
	}
	if (selectedAccount.value?.profile?.id) {
		return `https://mc-heads.net/avatar/${selectedAccount.value.profile.id}/128`
	}
	return STEVE_HEAD_URL
})

function getAccountAvatarUrl(account: MinecraftCredential) {
	if (account.account_type === 'offline') {
		return STEVE_HEAD_URL
	}
	if (
		account.profile.id === selectedAccount.value?.profile?.id &&
		equippedSkin.value?.texture_key
	) {
		const cachedUrl = equippedHeadUrl.value
		if (cachedUrl) {
			return cachedUrl
		}
	}
	return `https://mc-heads.net/avatar/${account.profile.id}/128`
}

async function setAccount(account: MinecraftCredential) {
	defaultUser.value = account.profile.id
	await set_default_user(account.profile.id).catch(handleError)
	await refreshValues()
	emit('change')
}

async function login() {
	loginDisabled.value = true
	const loggedIn = await login_flow().catch(handleSevereError)

	if (loggedIn) {
		await setAccount(loggedIn)
	}

	trackEvent('AccountLogIn')
	loginDisabled.value = false
}

async function logout(id: string) {
	await remove_user(id).catch(handleError)
	await refreshValues()
	if (!selectedAccount.value && accounts.value.length > 0) {
		await setAccount(accounts.value[0])
	} else {
		emit('change')
	}
	trackEvent('AccountLogOut')
}

const isOfflineNameValid = computed(() => OFFLINE_NAME_PATTERN.test(offlineName.value.trim()))

function openOfflineModal(account?: MinecraftCredential) {
	renameTarget.value = account ?? null
	offlineName.value = account?.profile.name ?? ''
	offlineError.value = ''
	offlineModal.value?.show()
}

async function submitOfflineModal() {
	const name = offlineName.value.trim()
	if (!OFFLINE_NAME_PATTERN.test(name)) {
		offlineError.value = formatMessage(messages.offlineNameInvalid)
		return
	}
	offlineSaving.value = true
	try {
		const credential = renameTarget.value
			? await rename_offline_user(renameTarget.value.profile.id, name)
			: await create_offline_user(name)
		offlineModal.value?.hide()
		await setAccount(credential)
		trackEvent('AccountLogIn', { source: 'OfflineAccount' })
	} catch (error) {
		offlineError.value = error instanceof Error ? error.message : String(error)
	} finally {
		offlineSaving.value = false
	}
}

useAppEvent('process', async (e) => {
	if (e.event === 'launched') {
		await refreshValues()
	}
})

const messages = defineMessages({
	notSignedIn: {
		id: 'minecraft-account.not-signed-in',
		defaultMessage: 'Not signed in',
	},
	addAccount: {
		id: 'minecraft-account.add-account',
		defaultMessage: 'Add account',
	},
	removeAccount: {
		id: 'minecraft-account.remove-account',
		defaultMessage: 'Remove account',
	},
	selectAccount: {
		id: 'minecraft-account.select-account',
		defaultMessage: 'Select account',
	},
	minecraftAccount: {
		id: 'minecraft-account.label',
		defaultMessage: 'Minecraft account',
	},
	signInToMinecraft: {
		id: 'minecraft-account.sign-in',
		defaultMessage: 'Sign in to Minecraft',
	},
	playOffline: {
		id: 'minecraft-account.play-offline',
		defaultMessage: 'Play offline',
	},
	offlineBadge: {
		id: 'minecraft-account.offline-badge',
		defaultMessage: 'Offline',
	},
	renameAccount: {
		id: 'minecraft-account.rename-account',
		defaultMessage: 'Rename account',
	},
	createOfflineHeader: {
		id: 'minecraft-account.create-offline-header',
		defaultMessage: 'Play offline',
	},
	renameOfflineHeader: {
		id: 'minecraft-account.rename-offline-header',
		defaultMessage: 'Rename offline account',
	},
	offlineNameLabel: {
		id: 'minecraft-account.offline-name-label',
		defaultMessage: 'Username',
	},
	offlineNamePlaceholder: {
		id: 'minecraft-account.offline-name-placeholder',
		defaultMessage: 'e.g. Alex_01',
	},
	offlineNameInvalid: {
		id: 'minecraft-account.offline-name-invalid',
		defaultMessage: 'Use 3-16 letters, numbers, or underscores.',
	},
	renameOfflineNote: {
		id: 'minecraft-account.rename-offline-note',
		defaultMessage:
			'Renaming creates a new identity with a different player UUID. Worlds and servers will treat it as a different player.',
	},
	cancel: {
		id: 'minecraft-account.cancel',
		defaultMessage: 'Cancel',
	},
	rename: {
		id: 'minecraft-account.rename',
		defaultMessage: 'Rename',
	},
	create: {
		id: 'minecraft-account.create',
		defaultMessage: 'Create',
	},
})
</script>
