<script setup>
import { ref, onMounted } from 'vue'
const status = ref('JS has not run')
onMounted(() => {
  status.value = 'vuefresh JS ran at ' + new Date().toISOString()
  document.documentElement.dataset.js = 'ran'
})
</script>

<template>
  <header>
    <h1>vuefresh</h1>
    <nav>
      <RouterLink to="/">Home</RouterLink> |
      <RouterLink to="/about">About</RouterLink>
    </nav>
    <p id="js-status">{{ status }}</p>
  </header>
  <main><RouterView /></main>
</template>
